#include "runtime_compat.h"
#include <Windows.h>
#if CDF_HAS_DIA
#include <dia2.h>
#endif
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <winver.h>

namespace {
struct File {
    HANDLE file=INVALID_HANDLE_VALUE,mapping=nullptr;const BYTE* data=nullptr;SIZE_T size=0;
    explicit File(const WCHAR* path){
        file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        LARGE_INTEGER length{};
        if(file==INVALID_HANDLE_VALUE||!GetFileSizeEx(file,&length)||length.QuadPart<=0||length.QuadPart>0x7fffffff)return;
        size=static_cast<SIZE_T>(length.QuadPart);mapping=CreateFileMappingW(file,nullptr,PAGE_READONLY,0,0,nullptr);
        if(mapping)data=static_cast<const BYTE*>(MapViewOfFile(mapping,FILE_MAP_READ,0,0,0));
    }
    ~File(){if(data)UnmapViewOfFile(data);if(mapping)CloseHandle(mapping);if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);}
};
std::string Utf8(const WCHAR* text){const int n=WideCharToMultiByte(CP_UTF8,0,text,-1,nullptr,0,nullptr,nullptr);std::string s(n?static_cast<size_t>(n):1,0);if(n)WideCharToMultiByte(CP_UTF8,0,text,-1,s.data(),n,nullptr,nullptr);s.resize(s.size()-1);return s;}
std::string Json(const std::string& s){std::string out="\"";for(unsigned char c:s){if(c=='"'||c=='\\'){out+='\\';out+=static_cast<char>(c);}else if(c<32){const char digits[]="0123456789abcdef";out+="\\u00";out+=digits[c>>4];out+=digits[c&15];}else out+=static_cast<char>(c);}return out+'"';}
std::string Hex(const BYTE* p,size_t n){constexpr char digits[]="0123456789ABCDEF";std::string s;for(size_t i=0;i<n;i++){s+=digits[p[i]>>4];s+=digits[p[i]&15];}return s;}
bool Symbols(const cdf::compat::Image& image,const WCHAR* path,const WCHAR* library){
#if !CDF_HAS_DIA
    (void)image;(void)path;(void)library;return false;
#else
    const BYTE* dir=image.data+image.pe+24+112+6*8;ULONG rva=0,length=0;memcpy(&rva,dir,4);memcpy(&length,dir+4,4);
    const BYTE* entries=image.At(rva,length);if(!entries||length%28)return false;GUID expected{};DWORD age=0;bool found=false;
    for(ULONG i=0;i<length;i+=28){DWORD kind=0,n=0,raw=0;memcpy(&kind,entries+i+12,4);memcpy(&n,entries+i+16,4);memcpy(&raw,entries+i+24,4);
        if(kind!=IMAGE_DEBUG_TYPE_CODEVIEW)continue;
        if(n<24||raw>image.size||n>image.size-raw||memcmp(image.data+raw,"RSDS",4))continue;
        memcpy(&expected,image.data+raw+4,16);memcpy(&age,image.data+raw+20,4);found=true;break;
    }
    if(!found)return false;
    const HRESULT initialized=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    HMODULE dia=nullptr;
    if(library){
        WCHAR full[MAX_PATH]{};
        const DWORD path_length=GetFullPathNameW(library,MAX_PATH,full,nullptr);
        if(path_length&&path_length<MAX_PATH)dia=LoadLibraryExW(full,nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
    using Class=HRESULT(WINAPI*)(REFCLSID,REFIID,void**);
    auto get=dia?reinterpret_cast<Class>(GetProcAddress(dia,"DllGetClassObject")):nullptr;
    IClassFactory* factory=nullptr;IDiaDataSource* source=nullptr;IDiaSession* session=nullptr;IDiaSymbol* global=nullptr;bool valid=false;
    if(library){
        if(get&&SUCCEEDED(get(__uuidof(DiaSource),IID_IClassFactory,reinterpret_cast<void**>(&factory))))
            factory->CreateInstance(nullptr,__uuidof(IDiaDataSource),reinterpret_cast<void**>(&source));
    }else CoCreateInstance(__uuidof(DiaSource),nullptr,CLSCTX_INPROC_SERVER,__uuidof(IDiaDataSource),reinterpret_cast<void**>(&source));
    if(source&&SUCCEEDED(source->loadDataFromPdb(path))&&SUCCEEDED(source->openSession(&session))&&SUCCEEDED(session->get_globalScope(&global))){
        GUID actual{};DWORD actual_age=0;valid=SUCCEEDED(global->get_guid(&actual))&&SUCCEEDED(global->get_age(&actual_age))&&IsEqualGUID(expected,actual)&&age==actual_age;
    }
    if(global)global->Release();if(session)session->Release();if(source)source->Release();if(factory)factory->Release();if(dia)FreeLibrary(dia);if(SUCCEEDED(initialized))CoUninitialize();return valid;
#endif
}
}
int wmain(int argc,WCHAR** argv){
    using namespace cdf::compat;
    const WCHAR *path=nullptr,*output=nullptr,*binding_path=nullptr,*symbols=nullptr,*dia_library=nullptr;bool capture=false;
    for(int i=1;i<argc;i++){
        const std::wstring key=argv[i];
        if(key==L"--capture"){capture=true;continue;}
        if(i+1>=argc)return 2;
        if(key==L"--image")path=argv[++i];else if(key==L"--binding-output")output=argv[++i];else if(key==L"--binding")binding_path=argv[++i];else if(key==L"--symbols")symbols=argv[++i];else if(key==L"--dia-library")dia_library=argv[++i];else return 2;
    }
    if(!path||(dia_library&&!symbols))return 2;File file(path);Image image{};Result result{};bool valid=false;
    if(file.data&&image.Open(file.data,file.size)){
        if(binding_path){File binding_file(binding_path);if(binding_file.data&&binding_file.size==sizeof(Binding)){
            Binding binding{};memcpy(&binding,binding_file.data,sizeof(binding));valid=ValidateBinding(image,binding,capture,result);
        }else result.failure=BindingInvalid;}
        else valid=Resolve(image,capture,true,result);
        if(symbols&&!Symbols(image,symbols,dia_library)){valid=false;result.failure=UnsupportedSymbols;}
    }else result.failure=InvalidPe;
    OSVERSIONINFOW os{};os.dwOSVersionInfoSize=sizeof(os);
    using Version=LONG(WINAPI*)(OSVERSIONINFOW*);auto version=reinterpret_cast<Version>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"RtlGetVersion"));
    if(!version||version(&os)<0||os.dwBuildNumber!=19045){valid=false;result.failure=UnsupportedWindows;}
    std::string electron_version;
    if(valid&&result.runtime&&!binding_path){
        DWORD ignored=0;const DWORD bytes=GetFileVersionInfoSizeW(path,&ignored);std::vector<BYTE> version_data(bytes);
        VS_FIXEDFILEINFO* info=nullptr;UINT info_bytes=0;
        if(bytes&&GetFileVersionInfoW(path,0,bytes,version_data.data())&&VerQueryValueW(version_data.data(),L"\\",reinterpret_cast<void**>(&info),&info_bytes)&&info_bytes>=sizeof(*info)&&HIWORD(info->dwFileVersionMS)==44){
            WCHAR text[64]{};swprintf_s(text,L"Electron %u.%u.%u / ABI v8-15.2",HIWORD(info->dwFileVersionMS),LOWORD(info->dwFileVersionMS),HIWORD(info->dwFileVersionLS));
            wcscpy_s(result.binding.runtime_version,text);
            std::ostringstream value;value<<HIWORD(info->dwFileVersionMS)<<'.'<<LOWORD(info->dwFileVersionMS)<<'.'<<HIWORD(info->dwFileVersionLS);electron_version=value.str();
        }
    }
    const auto& b=result.binding;WCHAR adapter_name[96]{};BindingName(b,adapter_name);BYTE binding_sha[32]{};Sha(reinterpret_cast<const BYTE*>(&b),sizeof(b),binding_sha);
    if(valid&&output&&result.runtime){std::ofstream target(output,std::ios::binary|std::ios::trunc);target.write(reinterpret_cast<const char*>(&b),sizeof(b));if(!target){valid=false;result.failure=BindingInvalid;}}
    const char* mode=b.match==ExactImage?"exact-image":b.match==EngineReuse?"same-engine":b.match==AbiResolved?"abi-resolved":b.match==NativeImage?"native":"unsupported";
    std::ostringstream s;s<<"{\"schemaVersion\":1,\"supported\":"<<(valid?"true":"false")<<",\"type\":\""<<(result.runtime?"electron":"native")<<"\",\"reason\":"<<(valid?"null":Json(FailureName(result.failure)))<<",\"failureCode\":"<<result.failure
        <<",\"match\":"<<Json(mode)<<",\"sha256\":"<<Json(Hex(b.image_sha256,32))<<",\"engineSha256\":"<<Json(Hex(b.engine_sha256,32))<<",\"bindingSha256\":"<<Json(Hex(binding_sha,32))<<",\"catalogSha256\":"<<Json(Hex(CatalogHash(),32))<<",\"catalogRevision\":"<<CatalogRevision()
        <<",\"windowsBuild\":"<<os.dwBuildNumber<<",\"imageSize\":"<<b.image_size<<",\"timestamp\":"<<b.timestamp<<",\"adapterId\":"<<Json(result.runtime?Utf8(adapter_name):"")<<",\"abiId\":"<<Json(result.runtime?Utf8(AbiName(b.abi_index)):"")
        <<",\"coreReady\":"<<(valid?"true":"false")<<",\"captureReady\":"<<(b.capture_ready?"true":"false")<<",\"failedRole\":"<<(valid||result.failed_role>=RoleCount?"null":Json(Utf8(RoleName(result.failed_role))))<<",\"candidates\":"<<result.candidates<<",\"sites\":[";
    for(ULONG r=0;r<RoleCount;r++){if(r)s<<',';s<<"{\"role\":"<<Json(Utf8(RoleName(r)))<<",\"rva\":"<<b.sites[r].rva<<",\"functionRva\":"<<b.sites[r].function_rva<<",\"functionBytes\":"<<b.sites[r].function_size<<",\"sha256\":"<<Json(Hex(b.sites[r].code_sha256,32))<<'}';}
    s<<"],\"versions\":{\"electron\":"<<(electron_version.empty()?"null":Json(electron_version))<<",\"abi\":"<<Json(result.runtime?Utf8(AbiName(b.abi_index)):"")<<"},\"symbolsVerified\":"<<(symbols&&valid?"true":"false")<<"}";std::cout<<s.str()<<std::endl;return valid?0:1;
}
