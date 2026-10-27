#include "runtime_provider.h"
#include "locale_native.h"
#include <inspectable.h>
#include <winstring.h>
#include <intrin.h>

// Deliberately use raw ABI interfaces, not SDK collection templates: the latter
// emit WindowsDeleteString and C++ runtime imports even with /NODEFAULTLIB.
namespace {
using HS=HSTRING;
struct Object;
struct Interface { PVOID* table; Object* owner; PVOID real; IID iid; };
static_assert(offsetof(Interface,real)==16);
using CreateString=HRESULT(WINAPI*)(PCNZWCH,UINT32,HS*);
using DeleteString=HRESULT(WINAPI*)(HS);
using GetString=PCWSTR(WINAPI*)(HS,UINT32*);
using CoAllocate=LPVOID(WINAPI*)(SIZE_T);
PVOID volatile api_functions[4]{};
template<class F> F Api(unsigned index){return reinterpret_cast<F>(_InterlockedCompareExchangePointer(api_functions+index,nullptr,nullptr));}
#define create_string Api<CreateString>(0)
#define delete_string Api<DeleteString>(1)
#define get_string Api<GetString>(2)
#define co_allocate Api<CoAllocate>(3)
alignas(8) volatile LONG64 language_calls=0,format_calls=0;
bool Eq(REFIID a,REFIID b){return reinterpret_cast<const ULONGLONG*>(&a)[0]==reinterpret_cast<const ULONGLONG*>(&b)[0]&&reinterpret_cast<const ULONGLONG*>(&a)[1]==reinterpret_cast<const ULONGLONG*>(&b)[1];}
bool Equal(PCWSTR a,PCWSTR b){if(!a||!b)return a==b;while(*a&&*a==*b){++a;++b;}return *a==*b;}
template<class F> F Method(PVOID object,unsigned index){return reinterpret_cast<F>((*static_cast<PVOID**>(object))[index]);}
HRESULT QI(PVOID object,REFIID iid,PVOID* out){return Method<HRESULT(WINAPI*)(PVOID,REFIID,PVOID*)>(object,0)(object,iid,out);}
ULONG Drop(PVOID object){return Method<ULONG(WINAPI*)(PVOID)>(object,2)(object);}
PVOID Heap(){return NtCurrentTeb()->ProcessEnvironmentBlock->Reserved4[1];}
void* Alloc(SIZE_T n){return RtlAllocateHeap(Heap(),HEAP_ZERO_MEMORY,n);}
void Free(void* p){RtlFreeHeap(Heap(),0,p);}
bool APIs(){
    if(create_string&&delete_string&&get_string&&co_allocate)return true;
    // Each caller can resolve the same immutable system exports independently.
    // Atomic publication avoids both a loader-lock wait and a transient failed
    // activation when two apartments reach their first activation together.
    auto c=reinterpret_cast<CreateString>(cdf::ResolveLoaded(L"combase.dll","WindowsCreateString"));
    auto d=reinterpret_cast<DeleteString>(cdf::ResolveLoaded(L"combase.dll","WindowsDeleteString"));
    auto g=reinterpret_cast<GetString>(cdf::ResolveLoaded(L"combase.dll","WindowsGetStringRawBuffer"));
    auto a=reinterpret_cast<CoAllocate>(cdf::ResolveLoaded(L"combase.dll","CoTaskMemAlloc"));
    if(!c||!d||!g||!a)return false;
    _InterlockedExchangePointer(api_functions+0,reinterpret_cast<PVOID>(c));
    _InterlockedExchangePointer(api_functions+1,reinterpret_cast<PVOID>(d));
    _InterlockedExchangePointer(api_functions+2,reinterpret_cast<PVOID>(g));
    _InterlockedExchangePointer(api_functions+3,reinterpret_cast<PVOID>(a));return true;
}
HRESULT String(PCWSTR text,HS* out){if(!out)return E_POINTER;UINT32 n=0;while(text[n])++n;return create_string(text,n,out);}
struct Text { HS value=nullptr; explicit Text(PCWSTR s){String(s,&value);} ~Text(){if(value)delete_string(value);} };
constexpr IID unknown={0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
constexpr IID inspectable={0xaf86e2e0,0xb12d,0x4c6a,{0x9c,0x5a,0xd7,0xaa,0x65,0x10,0x1e,0x90}};
constexpr IID agile={0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
constexpr IID activation={0x00000035,0,0,{0xc0,0,0,0,0,0,0,0x46}};
constexpr IID view_id={0x2f13c006,0xa03a,0x5f69,{0xb0,0x90,0x75,0xa4,0x3e,0x33,0x42,0x3e}};
constexpr IID iterable_id={0xe2fcc7c1,0x3bfc,0x5a0b,{0xb2,0xb0,0x72,0xe7,0x69,0xd1,0xcb,0x7e}};
constexpr IID iterator_id={0x8c304ebb,0x6615,0x50a4,{0x88,0x29,0x87,0x9e,0xcd,0x44,0x32,0x36}};
#define CDF_WINRT_ABI(name,slots,...) constexpr IID name=__VA_ARGS__;
#include "runtime_winrt_catalog.inc"
#undef CDF_WINRT_ABI
struct Spec { const IID* iid; unsigned slots; };
const Spec specs[]={
#define CDF_WINRT_ABI(name,slots,...) {&name,slots},
#include "runtime_winrt_catalog.inc"
#undef CDF_WINRT_ABI
    {&activation,7}
};
HRESULT CopyIids(const IID* ids,ULONG count,ULONG* size,IID** output){
    if(!size||!output)return E_POINTER;*size=0;*output=nullptr;
    auto* p=static_cast<IID*>(co_allocate(count*sizeof(IID)));if(!p)return E_OUTOFMEMORY;
    cdf::Copy(p,ids,count*sizeof(IID));*output=p;*size=count;return S_OK;
}
// Immutable MULTI_SZ collection. Every returned HSTRING has a fresh owning
// reference; iterators own the view and have independent cursor state.
struct Strings { Interface view,iterable;volatile LONG refs;ULONG count;WCHAR data[1024]; };
struct Cursor { Interface api;volatile LONG refs;Strings* strings;ULONG index; };
HRESULT WINAPI StringsQI(Interface* self,REFIID iid,PVOID* out){
    if(!out)return E_POINTER;*out=nullptr;auto* s=reinterpret_cast<Strings*>(self->owner);
    if(Eq(iid,unknown)||Eq(iid,inspectable)||Eq(iid,view_id)||Eq(iid,agile))*out=&s->view;
    else if(Eq(iid,iterable_id))*out=&s->iterable;else return E_NOINTERFACE;
    _InterlockedIncrement(&s->refs);return S_OK;
}
ULONG WINAPI StringsAdd(Interface* s){return _InterlockedIncrement(&reinterpret_cast<Strings*>(s->owner)->refs);}
ULONG WINAPI StringsDrop(Interface* s){auto* p=reinterpret_cast<Strings*>(s->owner);const LONG n=_InterlockedDecrement(&p->refs);if(!n)Free(p);return n;}
HRESULT WINAPI StringsIds(Interface*,ULONG* n,IID** p){const IID ids[]={view_id,iterable_id};return CopyIids(ids,2,n,p);}
HRESULT WINAPI StringsClass(Interface*,HS* out){return String(L"Windows.Foundation.Collections.StringVectorView",out);}
HRESULT WINAPI Trust(Interface*,TrustLevel* value){if(!value)return E_POINTER;*value=BaseTrust;return S_OK;}
PCWSTR At(Strings* s,ULONG index){PCWSTR p=s->data;while(index--){while(*p)++p;++p;}return p;}
HRESULT WINAPI GetAt(Interface* self,ULONG index,HS* out){if(!out)return E_POINTER;*out=nullptr;auto* s=reinterpret_cast<Strings*>(self->owner);return index>=s->count?E_BOUNDS:String(At(s,index),out);}
HRESULT WINAPI Size(Interface* self,ULONG* n){if(!n)return E_POINTER;*n=reinterpret_cast<Strings*>(self->owner)->count;return S_OK;}
HRESULT WINAPI IndexOf(Interface* self,HS text,ULONG* index,boolean* found){
    if(!index||!found)return E_POINTER;*index=0;*found=0;auto* s=reinterpret_cast<Strings*>(self->owner);
    for(ULONG i=0;i<s->count;i++)if(Equal(get_string(text,nullptr),At(s,i))){*index=i;*found=1;break;}return S_OK;
}
HRESULT WINAPI Many(Interface* self,ULONG start,ULONG capacity,HS* values,ULONG* count){
    if(!count||(capacity&&!values))return E_POINTER;*count=0;auto* s=reinterpret_cast<Strings*>(self->owner);
    if(start>s->count)return E_BOUNDS;
    const ULONG n=(s->count-start<capacity)?s->count-start:capacity;
    for(ULONG i=0;i<n;i++){const HRESULT hr=String(At(s,start+i),values+i);if(FAILED(hr)){while(i)delete_string(values[--i]);return hr;}}
    *count=n;return S_OK;
}
HRESULT WINAPI CursorQI(Interface* self,REFIID iid,PVOID* out){
    if(!out)return E_POINTER;*out=nullptr;
    if(!Eq(iid,unknown)&&!Eq(iid,inspectable)&&!Eq(iid,iterator_id)&&!Eq(iid,agile))return E_NOINTERFACE;
    *out=self;_InterlockedIncrement(&reinterpret_cast<Cursor*>(self->owner)->refs);return S_OK;
}
ULONG WINAPI CursorAdd(Interface* self){return _InterlockedIncrement(&reinterpret_cast<Cursor*>(self->owner)->refs);}
ULONG WINAPI CursorDrop(Interface* self){auto* c=reinterpret_cast<Cursor*>(self->owner);LONG n=_InterlockedDecrement(&c->refs);if(!n){StringsDrop(&c->strings->view);Free(c);}return n;}
HRESULT WINAPI CursorIds(Interface*,ULONG* n,IID** p){return CopyIids(&iterator_id,1,n,p);}
HRESULT WINAPI Current(Interface* self,HS* p){auto* c=reinterpret_cast<Cursor*>(self->owner);return GetAt(&c->strings->view,c->index,p);}
HRESULT WINAPI Has(Interface* self,boolean* p){if(!p)return E_POINTER;auto* c=reinterpret_cast<Cursor*>(self->owner);*p=c->index<c->strings->count;return S_OK;}
HRESULT WINAPI Next(Interface* self,boolean* p){if(!p)return E_POINTER;auto* c=reinterpret_cast<Cursor*>(self->owner);if(c->index<c->strings->count)++c->index;return Has(self,p);}
HRESULT WINAPI CursorMany(Interface* self,ULONG capacity,HS* values,ULONG* n){auto* c=reinterpret_cast<Cursor*>(self->owner);const HRESULT hr=Many(&c->strings->view,c->index,capacity,values,n);if(SUCCEEDED(hr))c->index+=*n;return hr;}
#define FP(f) reinterpret_cast<PVOID>(f)
PVOID cursor_table[]={FP(CursorQI),FP(CursorAdd),FP(CursorDrop),FP(CursorIds),FP(StringsClass),FP(Trust),FP(Current),FP(Has),FP(Next),FP(CursorMany)};
HRESULT WINAPI First(Interface* self,Interface** out){
    if(!out)return E_POINTER;*out=nullptr;auto* c=static_cast<Cursor*>(Alloc(sizeof(Cursor)));if(!c)return E_OUTOFMEMORY;
    c->api.table=cursor_table;c->api.owner=reinterpret_cast<Object*>(c);c->refs=1;c->strings=reinterpret_cast<Strings*>(self->owner);
    StringsAdd(&c->strings->view);*out=&c->api;return S_OK;
}
PVOID view_table[]={FP(StringsQI),FP(StringsAdd),FP(StringsDrop),FP(StringsIds),FP(StringsClass),FP(Trust),FP(GetAt),FP(Size),FP(IndexOf),FP(Many)};
PVOID iterable_table[]={FP(StringsQI),FP(StringsAdd),FP(StringsDrop),FP(StringsIds),FP(StringsClass),FP(Trust),FP(First)};
HRESULT List(PCWSTR multi,Interface** out){
    if(!out)return E_POINTER;*out=nullptr;auto* s=static_cast<Strings*>(Alloc(sizeof(Strings)));if(!s)return E_OUTOFMEMORY;
    s->view.table=view_table;s->iterable.table=iterable_table;s->view.owner=s->iterable.owner=reinterpret_cast<Object*>(s);s->refs=1;
    ULONG i=0;while(multi&&multi[i]&&i<1022){++s->count;do{s->data[i]=multi[i];++i;}while(multi[i]&&i<1022);++i;}
    if(i>=1022){Free(s);return E_INVALIDARG;}*out=&s->view;return S_OK;
}
HRESULT Single(PCWSTR text,Interface** out){WCHAR multi[LOCALE_NAME_MAX_LENGTH+1]{};cdf::CopyText(multi,LOCALE_NAME_MAX_LENGTH,text);return List(multi,out);}
enum class Kind { Preferences,UserPreferences,Application,DateFactory,Date,DecimalActivation,PercentActivation,PermilleActivation,CurrencyFactory,GeographicActivation };
struct Object {volatile LONG refs;volatile LONG lock;Kind kind;unsigned count;Interface faces[24];PVOID tables[24][40];};
#define DECLARE_FORWARD(n) extern "C" void CdfWinrtForward##n();
DECLARE_FORWARD(6) DECLARE_FORWARD(7) DECLARE_FORWARD(8) DECLARE_FORWARD(9) DECLARE_FORWARD(10) DECLARE_FORWARD(11) DECLARE_FORWARD(12) DECLARE_FORWARD(13) DECLARE_FORWARD(14) DECLARE_FORWARD(15) DECLARE_FORWARD(16) DECLARE_FORWARD(17) DECLARE_FORWARD(18) DECLARE_FORWARD(19) DECLARE_FORWARD(20) DECLARE_FORWARD(21) DECLARE_FORWARD(22) DECLARE_FORWARD(23) DECLARE_FORWARD(24) DECLARE_FORWARD(25) DECLARE_FORWARD(26) DECLARE_FORWARD(27) DECLARE_FORWARD(28) DECLARE_FORWARD(29) DECLARE_FORWARD(30) DECLARE_FORWARD(31) DECLARE_FORWARD(32) DECLARE_FORWARD(33) DECLARE_FORWARD(34) DECLARE_FORWARD(35) DECLARE_FORWARD(36) DECLARE_FORWARD(37) DECLARE_FORWARD(38) DECLARE_FORWARD(39)
PVOID forwards[]={nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,
FP(CdfWinrtForward6),FP(CdfWinrtForward7),FP(CdfWinrtForward8),FP(CdfWinrtForward9),FP(CdfWinrtForward10),FP(CdfWinrtForward11),FP(CdfWinrtForward12),FP(CdfWinrtForward13),FP(CdfWinrtForward14),FP(CdfWinrtForward15),FP(CdfWinrtForward16),FP(CdfWinrtForward17),FP(CdfWinrtForward18),FP(CdfWinrtForward19),FP(CdfWinrtForward20),FP(CdfWinrtForward21),FP(CdfWinrtForward22),FP(CdfWinrtForward23),FP(CdfWinrtForward24),FP(CdfWinrtForward25),FP(CdfWinrtForward26),FP(CdfWinrtForward27),FP(CdfWinrtForward28),FP(CdfWinrtForward29),FP(CdfWinrtForward30),FP(CdfWinrtForward31),FP(CdfWinrtForward32),FP(CdfWinrtForward33),FP(CdfWinrtForward34),FP(CdfWinrtForward35),FP(CdfWinrtForward36),FP(CdfWinrtForward37),FP(CdfWinrtForward38),FP(CdfWinrtForward39)};
void Customize(Interface* face);
HRESULT WINAPI ProxyQI(Interface* self,REFIID iid,PVOID* out);
ULONG WINAPI ProxyAdd(Interface* self){return _InterlockedIncrement(&self->owner->refs);}
ULONG WINAPI ProxyDrop(Interface* self){auto* o=self->owner;const LONG n=_InterlockedDecrement(&o->refs);if(!n){for(unsigned i=0;i<o->count;i++)Drop(o->faces[i].real);Free(o);}return n;}
HRESULT WINAPI ProxyIds(Interface* self,ULONG* n,IID** p){return Method<HRESULT(WINAPI*)(PVOID,ULONG*,IID**)>(self->real,3)(self->real,n,p);}
HRESULT WINAPI ProxyClass(Interface* self,HS* p){return Method<HRESULT(WINAPI*)(PVOID,HS*)>(self->real,4)(self->real,p);}
HRESULT WINAPI ProxyTrust(Interface* self,TrustLevel* p){return Method<HRESULT(WINAPI*)(PVOID,TrustLevel*)>(self->real,5)(self->real,p);}
Interface* AddFace(Object* o,PVOID real,REFIID iid,unsigned slots){
    if(o->count>=24||slots>40)return nullptr;const unsigned n=o->count++;
    auto* f=&o->faces[n];f->table=o->tables[n];f->owner=o;f->real=real;f->iid=iid;
    f->table[0]=FP(ProxyQI);f->table[1]=FP(ProxyAdd);f->table[2]=FP(ProxyDrop);f->table[3]=FP(ProxyIds);f->table[4]=FP(ProxyClass);f->table[5]=FP(ProxyTrust);
    for(unsigned i=6;i<slots;i++)f->table[i]=forwards[i];Customize(f);return f;
}
HRESULT WINAPI ProxyQI(Interface* self,REFIID iid,PVOID* out){
    if(!out)return E_POINTER;*out=nullptr;auto* o=self->owner;
    if(Eq(iid,unknown)||Eq(iid,inspectable)){*out=&o->faces[0];ProxyAdd(self);return S_OK;}
    if(Eq(iid,agile)){PVOID real=nullptr;const HRESULT hr=QI(self->real,iid,&real);if(FAILED(hr))return hr;Drop(real);*out=&o->faces[0];ProxyAdd(self);return S_OK;}
    // QI can run concurrently. No lock is held across calls into COM.
    PVOID real=nullptr;const HRESULT hr=QI(self->real,iid,&real);if(FAILED(hr))return hr;
    const Spec* spec=nullptr;for(const auto& s:specs)if(Eq(iid,*s.iid)){spec=&s;break;}
    if(!spec){Drop(real);return E_NOINTERFACE;}
    while(_InterlockedCompareExchange(&o->lock,1,0))_mm_pause();
    Interface* f=nullptr;for(unsigned i=0;i<o->count;i++)if(Eq(o->faces[i].iid,iid)){f=&o->faces[i];break;}
    if(f)Drop(real);else f=AddFace(o,real,iid,spec->slots);
    if(f){*out=f;ProxyAdd(f);}else Drop(real);
    _InterlockedExchange(&o->lock,0);return f?S_OK:E_OUTOFMEMORY;
}
HRESULT Wrap(PVOID real,REFIID iid,Kind kind,PVOID* out){
    const Spec* spec=nullptr;for(const auto& s:specs)if(Eq(iid,*s.iid)){spec=&s;break;}
    if(!spec)return S_FALSE;
    auto* o=static_cast<Object*>(Alloc(sizeof(Object)));if(!o)return E_OUTOFMEMORY;o->refs=1;o->kind=kind;
    auto* f=AddFace(o,real,iid,spec->slots);if(!f){Free(o);return E_OUTOFMEMORY;}*out=f;return S_OK;
}
HRESULT WINAPI Languages(Interface*,Interface** out){_InterlockedIncrement64(&language_calls);return Single(cdf::RuntimeConfigSnapshot().locale.ui_language,out);}
HRESULT WINAPI Region(Interface*,HS* out){return String(cdf::RuntimeConfigSnapshot().region.home_region,out);}
bool CurrentUser(PVOID user);
HRESULT WINAPI ForUser(Interface* self,PVOID user,PVOID* out){
    const HRESULT hr=Method<HRESULT(WINAPI*)(PVOID,PVOID,PVOID*)>(self->real,6)(self->real,user,out);
    if(FAILED(hr)||!out||!*out||!CurrentUser(user))return hr;
    PVOID proxy=nullptr;const HRESULT wrapped=Wrap(*out,IGlobalizationPreferencesForUser,Kind::UserPreferences,&proxy);
    if(wrapped==S_OK)*out=proxy;else if(FAILED(wrapped)){Drop(*out);*out=nullptr;return wrapped;}return hr;
}
// App-specific language overrides remain owned by Windows. Querying the real
// PrimaryLanguageOverride detects and preserves successful application choices.
HRESULT WINAPI AppLanguages(Interface* self,Interface** out){
    PVOID statics=nullptr;const HRESULT qi=QI(self->real,IApplicationLanguagesStatics,&statics);
    if(FAILED(qi))return qi;HS value=nullptr;
    const HRESULT hr=Method<HRESULT(WINAPI*)(PVOID,HS*)>(statics,6)(statics,&value);
    bool explicit_language=false;if(SUCCEEDED(hr)){UINT32 n=0;get_string(value,&n);explicit_language=n!=0;if(value)delete_string(value);}
    HRESULT result=hr;
    if(SUCCEEDED(hr)||hr==HRESULT_FROM_WIN32(APPMODEL_ERROR_NO_PACKAGE)){
        if(explicit_language)result=Method<HRESULT(WINAPI*)(PVOID,Interface**)>(statics,8)(statics,out);
        else{WCHAR list[1024]{};result=cdf::LocaleProcessLanguages(list,1024)?List(list,out):Languages(self,out);}
    }
    Drop(statics);return result;
}
HRESULT WINAPI AppForUser(Interface* self,PVOID user,Interface** out){
    PVOID statics=nullptr;const HRESULT hr=QI(self->real,IApplicationLanguagesStatics,&statics);if(FAILED(hr))return hr;
    HS choice=nullptr;HRESULT result=Method<HRESULT(WINAPI*)(PVOID,HS*)>(statics,6)(statics,&choice);
    UINT32 n=0;if(SUCCEEDED(result))get_string(choice,&n);if(choice)delete_string(choice);Drop(statics);
    if(FAILED(result)&&result!=HRESULT_FROM_WIN32(APPMODEL_ERROR_NO_PACKAGE))return result;
    if(n)return Method<HRESULT(WINAPI*)(PVOID,PVOID,Interface**)>(self->real,6)(self->real,user,out);
    // Validate the user object through Windows before replacing its result.
    result=Method<HRESULT(WINAPI*)(PVOID,PVOID,Interface**)>(self->real,6)(self->real,user,out);
    if(FAILED(result)||!out||!*out||!CurrentUser(user))return result;Drop(*out);*out=nullptr;return AppLanguages(self,out);
}
HRESULT Factory(PCWSTR name,REFIID iid,PVOID* out){
    using Fn=HRESULT(WINAPI*)(HS,REFIID,PVOID*);
    const auto raw=reinterpret_cast<Fn>(cdf::ResolveLoaded(L"combase.dll","RoGetActivationFactory"));
    Text class_name(name);if(!class_name.value)return E_OUTOFMEMORY;
    return raw?raw(class_name.value,iid,out):E_UNEXPECTED;
}
bool CurrentUser(PVOID user){
    if(!user)return true;
    constexpr IID statics2={0x74a37e11,0x2eb5,0x4487,{0xb0,0xd5,0x2c,0x67,0x90,0xe0,0x13,0xe9}};
    PVOID factory=nullptr,current=nullptr;HRESULT hr=Factory(L"Windows.System.User",statics2,&factory);
    if(FAILED(hr))return false;hr=Method<HRESULT(WINAPI*)(PVOID,PVOID*)>(factory,6)(factory,&current);Drop(factory);if(FAILED(hr)||!current)return false;
    HS a=nullptr,b=nullptr;const HRESULT x=Method<HRESULT(WINAPI*)(PVOID,HS*)>(current,6)(current,&a),y=Method<HRESULT(WINAPI*)(PVOID,HS*)>(user,6)(user,&b);
    const bool equal=SUCCEEDED(x)&&SUCCEEDED(y)&&Equal(get_string(a,nullptr),get_string(b,nullptr));if(a)delete_string(a);if(b)delete_string(b);Drop(current);return equal;
}
void ContextRegion(WCHAR* output){
    if(cdf::RuntimeRegionEnabled()){cdf::CopyText(output,85,cdf::RuntimeConfigSnapshot().region.home_region);return;}
    const auto raw=reinterpret_cast<decltype(&GetUserDefaultGeoName)>(cdf::ResolveLoaded(L"kernelbase.dll","GetUserDefaultGeoName"));
    if(!raw||!raw(output,85))output[0]=0;
}
PCWSTR Clock(PCWSTR locale){
    const auto raw=reinterpret_cast<decltype(&GetLocaleInfoEx)>(cdf::ResolveLoaded(L"kernelbase.dll","GetLocaleInfoEx"));
    WCHAR data[8]{};if(raw&&raw(locale,LOCALE_ITIME|LOCALE_NOUSEROVERRIDE,data,8)&&data[0]==L'0')return L"12HourClock";
    return L"24HourClock";
}
PCWSTR Calendar(PCWSTR locale){
    const auto raw=reinterpret_cast<decltype(&GetLocaleInfoEx)>(cdf::ResolveLoaded(L"kernelbase.dll","GetLocaleInfoEx"));
    DWORD value=0;if(!raw||!raw(locale,LOCALE_ICALENDARTYPE|LOCALE_RETURN_NUMBER|LOCALE_NOUSEROVERRIDE,reinterpret_cast<LPWSTR>(&value),sizeof(value)/sizeof(WCHAR)))return nullptr;
    switch(value){
    case CAL_GREGORIAN:case CAL_GREGORIAN_US:case CAL_GREGORIAN_ME_FRENCH:case CAL_GREGORIAN_ARABIC:case CAL_GREGORIAN_XLIT_ENGLISH:case CAL_GREGORIAN_XLIT_FRENCH:return L"GregorianCalendar";
    case CAL_JAPAN:return L"JapaneseCalendar";case CAL_TAIWAN:return L"TaiwanCalendar";
    case CAL_KOREA:return L"KoreanCalendar";case CAL_HIJRI:return L"HijriCalendar";
    case CAL_THAI:return L"ThaiCalendar";case CAL_HEBREW:return L"HebrewCalendar";
    case CAL_PERSIAN:return L"PersianCalendar";case CAL_UMALQURA:return L"UmAlQuraCalendar";
    default:return nullptr;
    }
}
HRESULT WrapDate(PVOID* out,HRESULT hr){
    if(FAILED(hr)||!out||!*out)return hr;PVOID proxy=nullptr;const HRESULT w=Wrap(*out,IDateTimeFormatter,Kind::Date,&proxy);
    if(w==S_OK)*out=proxy;else if(FAILED(w)){Drop(*out);*out=nullptr;return w;}return hr;
}
HRESULT DateContext(PVOID factory,HS templ,Interface* languages,HS region,HS calendar,HS clock,PVOID* out){
    return Method<HRESULT(WINAPI*)(PVOID,HS,Interface*,HS,HS,HS,PVOID*)>(factory,8)(factory,templ,languages,region,calendar,clock,out);
}
HRESULT DefaultDate(PVOID factory,HS templ,Interface* explicit_languages,PVOID* out){
    const PCWSTR calendar_name=Calendar(cdf::RuntimeConfigSnapshot().locale.format_locale);if(!calendar_name)return E_INVALIDARG;
    Interface* list=nullptr;HRESULT hr=Single(cdf::RuntimeConfigSnapshot().locale.format_locale,&list);if(FAILED(hr))return hr;
    WCHAR home[85]{};ContextRegion(home);Text region(home),calendar(calendar_name),clock(Clock(cdf::RuntimeConfigSnapshot().locale.format_locale));
    Interface* iterable=explicit_languages?explicit_languages:&reinterpret_cast<Strings*>(list->owner)->iterable;
    hr=DateContext(factory,templ,iterable,region.value,calendar.value,clock.value,out);Drop(list);return WrapDate(out,hr);
}
HRESULT ReformatDate(PVOID factory,PVOID* out,HRESULT hr,Interface* languages=nullptr){
    if(FAILED(hr)||!out||!*out)return hr;
    if(!cdf::RuntimeLocaleEnabled())return WrapDate(out,hr);
    HS templ=nullptr;const HRESULT got=Method<HRESULT(WINAPI*)(PVOID,HS*)>(*out,13)(*out,&templ);
    if(FAILED(got)){Drop(*out);*out=nullptr;return got;}
    Drop(*out);*out=nullptr;hr=DefaultDate(factory,templ,languages,out);if(templ)delete_string(templ);return hr;
}
HRESULT WINAPI DateTemplate(Interface* self,HS templ,PVOID* out){
    if(!cdf::RuntimeLocaleEnabled())return WrapDate(out,Method<HRESULT(WINAPI*)(PVOID,HS,PVOID*)>(self->real,6)(self->real,templ,out));
    return DefaultDate(self->real,templ,nullptr,out);
}
HRESULT WINAPI DateLanguages(Interface* self,HS templ,Interface* languages,PVOID* out){
    // Explicit language choice is preserved, including its default calendar/clock.
    return WrapDate(out,Method<HRESULT(WINAPI*)(PVOID,HS,Interface*,PVOID*)>(self->real,7)(self->real,templ,languages,out));
}
HRESULT WINAPI DateExplicit(Interface* self,HS templ,Interface* languages,HS region,HS calendar,HS clock,PVOID* out){return WrapDate(out,DateContext(self->real,templ,languages,region,calendar,clock,out));}
HRESULT WINAPI DateEnums(Interface* self,int year,int month,int day,int week,PVOID* out){
    const HRESULT hr=Method<HRESULT(WINAPI*)(PVOID,int,int,int,int,PVOID*)>(self->real,9)(self->real,year,month,day,week,out);return ReformatDate(self->real,out,hr);
}
HRESULT WINAPI TimeEnums(Interface* self,int hour,int minute,int second,PVOID* out){
    const HRESULT hr=Method<HRESULT(WINAPI*)(PVOID,int,int,int,PVOID*)>(self->real,10)(self->real,hour,minute,second,out);return ReformatDate(self->real,out,hr);
}
HRESULT WINAPI DateTimeLanguages(Interface* self,int y,int m,int d,int w,int h,int n,int s,Interface* languages,PVOID* out){
    return WrapDate(out,Method<HRESULT(WINAPI*)(PVOID,int,int,int,int,int,int,int,Interface*,PVOID*)>(self->real,11)(self->real,y,m,d,w,h,n,s,languages,out));
}
HRESULT WINAPI DateTimeContext(Interface* self,int y,int m,int d,int w,int h,int n,int s,Interface* languages,HS region,HS calendar,HS clock,PVOID* out){
    return WrapDate(out,Method<HRESULT(WINAPI*)(PVOID,int,int,int,int,int,int,int,Interface*,HS,HS,HS,PVOID*)>(self->real,12)(self->real,y,m,d,w,h,n,s,languages,region,calendar,clock,out));
}
HRESULT StaticDate(Interface* self,PCWSTR templ,unsigned index,PVOID* out){
    if(!cdf::RuntimeLocaleEnabled())return WrapDate(out,Method<HRESULT(WINAPI*)(PVOID,PVOID*)>(self->real,index)(self->real,out));
    PVOID factory=nullptr;HRESULT hr=QI(self->real,IDateTimeFormatterFactory,&factory);if(FAILED(hr))return hr;
    Text text(templ);hr=DefaultDate(factory,text.value,nullptr,out);Drop(factory);return hr;
}
HRESULT WINAPI LongDate(Interface* s,PVOID* o){return StaticDate(s,L"longdate",6,o);}
HRESULT WINAPI LongTime(Interface* s,PVOID* o){return StaticDate(s,L"longtime",7,o);}
HRESULT WINAPI ShortDate(Interface* s,PVOID* o){return StaticDate(s,L"shortdate",8,o);}
HRESULT WINAPI ShortTime(Interface* s,PVOID* o){return StaticDate(s,L"shorttime",9,o);}
HRESULT WINAPI DateFormat(Interface* self,LONGLONG value,HS* out){
    _InterlockedIncrement64(&format_calls);
    if(!cdf::RuntimeTimeEnabled())return Method<HRESULT(WINAPI*)(PVOID,LONGLONG,HS*)>(self->real,14)(self->real,value,out);
    PVOID second=nullptr;HRESULT hr=QI(self->real,IDateTimeFormatter2,&second);if(FAILED(hr))return hr;
    const struct Mapping{PCWSTR windows,iana;} mapping[]={
#include "windows_iana_cldr48.inc"
    };
    PCWSTR zone_name=nullptr;for(const auto& item:mapping)if(Equal(item.windows,cdf::RuntimeConfigSnapshot().zone_id)){zone_name=item.iana;break;}
    if(!zone_name){Drop(second);return E_INVALIDARG;}Text zone(zone_name);
    hr=Method<HRESULT(WINAPI*)(PVOID,LONGLONG,HS,HS*)>(second,6)(second,value,zone.value,out);Drop(second);return hr;
}
HRESULT NumberDefault(Kind kind,PVOID* out){
    PCWSTR name=nullptr;const IID* iid=nullptr;
    if(kind==Kind::DecimalActivation){name=L"Windows.Globalization.NumberFormatting.DecimalFormatter";iid=&IDecimalFormatterFactory;}
    else if(kind==Kind::PercentActivation){name=L"Windows.Globalization.NumberFormatting.PercentFormatter";iid=&IPercentFormatterFactory;}
    else{name=L"Windows.Globalization.NumberFormatting.PermilleFormatter";iid=&IPermilleFormatterFactory;}
    PVOID factory=nullptr;HRESULT hr=Factory(name,*iid,&factory);if(FAILED(hr))return hr;
    Interface* list=nullptr;hr=Single(cdf::RuntimeConfigSnapshot().locale.format_locale,&list);
    if(SUCCEEDED(hr)){WCHAR home[85]{};ContextRegion(home);Text region(home);
        hr=Method<HRESULT(WINAPI*)(PVOID,Interface*,HS,PVOID*)>(factory,6)(factory,&reinterpret_cast<Strings*>(list->owner)->iterable,region.value,out);Drop(list);}
    Drop(factory);return hr;
}
HRESULT WINAPI Currency(Interface* self,HS code,PVOID* out){
    Interface* list=nullptr;HRESULT hr=Single(cdf::RuntimeConfigSnapshot().locale.format_locale,&list);if(FAILED(hr))return hr;
    WCHAR home[85]{};ContextRegion(home);Text region(home);
    hr=Method<HRESULT(WINAPI*)(PVOID,HS,Interface*,HS,PVOID*)>(self->real,7)(self->real,code,&reinterpret_cast<Strings*>(list->owner)->iterable,region.value,out);Drop(list);return hr;
}
HRESULT Geographic(PVOID* out){
    PVOID factory=nullptr;HRESULT hr=Factory(L"Windows.Globalization.GeographicRegion",IGeographicRegionFactory,&factory);if(FAILED(hr))return hr;
    Text code(cdf::RuntimeConfigSnapshot().region.home_region);
    hr=Method<HRESULT(WINAPI*)(PVOID,HS,PVOID*)>(factory,6)(factory,code.value,out);Drop(factory);return hr;
}
HRESULT WINAPI DefaultActivate(Interface* self,PVOID* out){
    if(self->owner->kind==Kind::GeographicActivation)return Geographic(out);
    return NumberDefault(self->owner->kind,out);
}
// Factory forwarding overrides are added below. All other properties (rounding,
// parsing, precision, numeral system) keep their original ABI and real object.
void Customize(Interface* f){
    const auto kind=f->owner->kind;
    if(kind==Kind::Preferences&&Eq(f->iid,IGlobalizationPreferencesStatics)){
        if(cdf::RuntimeLocaleEnabled())f->table[9]=FP(Languages);
        if(cdf::RuntimeRegionEnabled())f->table[10]=FP(Region);
    }
    if(kind==Kind::Preferences&&Eq(f->iid,IGlobalizationPreferencesStatics3))f->table[6]=FP(ForUser);
    if(kind==Kind::UserPreferences&&Eq(f->iid,IGlobalizationPreferencesForUser)){
        if(cdf::RuntimeLocaleEnabled())f->table[10]=FP(Languages);
        if(cdf::RuntimeRegionEnabled())f->table[11]=FP(Region);
    }
    if(kind==Kind::Application&&Eq(f->iid,IApplicationLanguagesStatics)&&cdf::RuntimeLocaleEnabled())f->table[8]=FP(AppLanguages);
    if(kind==Kind::Application&&Eq(f->iid,IApplicationLanguagesStatics2)&&cdf::RuntimeLocaleEnabled())f->table[6]=FP(AppForUser);
    if(kind==Kind::DateFactory&&Eq(f->iid,IDateTimeFormatterFactory)){
        const PVOID methods[]={FP(DateTemplate),FP(DateLanguages),FP(DateExplicit),FP(DateEnums),FP(TimeEnums),FP(DateTimeLanguages),FP(DateTimeContext)};
        for(unsigned i=0;i<7;i++)f->table[6+i]=methods[i];
    }
    if(kind==Kind::DateFactory&&Eq(f->iid,IDateTimeFormatterStatics)){
        f->table[6]=FP(LongDate);f->table[7]=FP(LongTime);f->table[8]=FP(ShortDate);f->table[9]=FP(ShortTime);
    }
    if(kind==Kind::Date&&Eq(f->iid,IDateTimeFormatter))f->table[14]=FP(DateFormat);
    if(kind==Kind::CurrencyFactory&&Eq(f->iid,ICurrencyFormatterFactory))f->table[6]=FP(Currency);
    if((kind==Kind::DecimalActivation||kind==Kind::PercentActivation||kind==Kind::PermilleActivation||kind==Kind::GeographicActivation)&&Eq(f->iid,activation))f->table[6]=FP(DefaultActivate);
}
}
namespace cdf {
HRESULT WrapRuntimeFactory(void* name,REFIID iid,void** output){
    if(!APIs())return E_UNEXPECTED;
    const PCWSTR text=get_string(static_cast<HS>(name),nullptr);Kind kind;
    if(Equal(text,L"Windows.System.UserProfile.GlobalizationPreferences"))kind=Kind::Preferences;
    else if(Equal(text,L"Windows.Globalization.ApplicationLanguages")&&RuntimeLocaleEnabled())kind=Kind::Application;
    else if(Equal(text,L"Windows.Globalization.DateTimeFormatting.DateTimeFormatter")&&RuntimeConfigSnapshot().runtime.enabled)kind=Kind::DateFactory;
    else if(Equal(text,L"Windows.Globalization.NumberFormatting.DecimalFormatter")&&RuntimeLocaleEnabled())kind=Kind::DecimalActivation;
    else if(Equal(text,L"Windows.Globalization.NumberFormatting.PercentFormatter")&&RuntimeLocaleEnabled())kind=Kind::PercentActivation;
    else if(Equal(text,L"Windows.Globalization.NumberFormatting.PermilleFormatter")&&RuntimeLocaleEnabled())kind=Kind::PermilleActivation;
    else if(Equal(text,L"Windows.Globalization.NumberFormatting.CurrencyFormatter")&&RuntimeLocaleEnabled())kind=Kind::CurrencyFactory;
    else if(Equal(text,L"Windows.Globalization.GeographicRegion")&&RuntimeRegionEnabled())kind=Kind::GeographicActivation;
    else return S_FALSE;
    PVOID proxy=nullptr;const HRESULT hr=Wrap(*output,iid,kind,&proxy);
    if(hr==S_OK)*output=proxy;
    else if(FAILED(hr)){Drop(*output);*output=nullptr;}return hr;
}
HRESULT ActivateRuntimeInstance(void* name,void** out){
    if(!RuntimePrepared()||!APIs())return S_FALSE;
    const PCWSTR text=get_string(static_cast<HS>(name),nullptr);
    if(RuntimeRegionEnabled()&&Equal(text,L"Windows.Globalization.GeographicRegion"))return Geographic(out);
    if(RuntimeLocaleEnabled()){
        if(Equal(text,L"Windows.Globalization.NumberFormatting.DecimalFormatter"))return NumberDefault(Kind::DecimalActivation,out);
        if(Equal(text,L"Windows.Globalization.NumberFormatting.PercentFormatter"))return NumberDefault(Kind::PercentActivation,out);
        if(Equal(text,L"Windows.Globalization.NumberFormatting.PermilleFormatter"))return NumberDefault(Kind::PermilleActivation,out);
    }
    return S_FALSE;
}
ULONGLONG WinrtLanguageCalls(){return static_cast<ULONGLONG>(_InterlockedCompareExchange64(&language_calls,0,0));}
ULONGLONG WinrtFormatCalls(){return static_cast<ULONGLONG>(_InterlockedCompareExchange64(&format_calls,0,0));}
}
