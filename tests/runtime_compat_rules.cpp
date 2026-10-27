#include "runtime_compat.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <cstring>
#include <algorithm>
int wmain(int argc,wchar_t** argv){
    using namespace cdf::compat;if(argc!=2)return 2;
    std::ifstream file(argv[1],std::ios::binary|std::ios::ate);if(!file)return 3;const auto length=file.tellg();file.seekg(0);
    std::vector<BYTE> data(static_cast<size_t>(length));file.read(reinterpret_cast<char*>(data.data()),length);
    unsigned checks=0;std::vector<std::string> failures;
    const auto check=[&](bool value,const char* label){++checks;if(!value)failures.emplace_back(label);};
    Image image{};check(image.Open(data.data(),data.size()),"valid AMD64 PE");Result base{};
    check(Resolve(image,true,true,base)&&base.binding.match==ExactImage&&base.binding.capture_ready,"exact image and complete capture group");
    Result result{};check(ValidateBinding(image,base.binding,true,result),"binding round trip");
    for(unsigned fault=0;fault<7;fault++){
        Binding altered=base.binding;
        if(fault==0)altered.magic^=1;if(fault==1)altered.catalog_sha256[0]^=1;if(fault==2)altered.sites[PublicLocale].rva=0x7fffffff;
        if(fault==3)altered.sites[PublicLocale].code_sha256[0]^=1;if(fault==4)altered.image_sha256[0]^=1;if(fault==5)altered.abi_index=10000;
        if(fault==6)altered.engine_sha256[0]^=1;
        check(!ValidateBinding(image,altered,true,result),"malformed stale or foreign binding rejected");
    }
    const BYTE saved=data[28];data[28]^=1;
    check(Resolve(image,true,true,result)&&result.binding.match==EngineReuse,"DOS packaging change reuses engine without full-image allowlist");data[28]=saved;
    const char sentinel[]="dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX";
    auto fuse=std::search(data.begin(),data.end(),sentinel,sentinel+sizeof(sentinel)-1);
    check(fuse!=data.end(),"known fuse sentinel");
    if(fuse!=data.end()){
        const auto index=static_cast<size_t>(fuse-data.begin())+34;const BYTE old=data[index];data[index]=old=='1'?'0':'1';
        check(Resolve(image,true,true,result)&&result.binding.match==EngineReuse,"recognized package fuse state normalizes only that wire");
        data[index]='x';check(!Resolve(image,true,true,result)&&result.failure==InvalidFuse,"unknown fuse state rejected");data[index]=old;
    }
    const auto* target=image.At(base.binding.sites[PublicLocale].rva,89);const size_t target_offset=target-data.data();
    const BYTE field=data[target_offset+16];data[target_offset+16]^=1;
    check(!Resolve(image,true,true,result)&&result.failed_role==PublicLocale,"changed object field offset cannot pass an ABI locator");data[target_offset+16]=field;
    const BYTE call=data[target_offset+0x1e];data[target_offset+0x1e]^=1;
    check(!Resolve(image,true,true,result)&&result.failure==AbiMismatch,"retargeting a masked displacement fails the function relationship");data[target_offset+0x1e]=call;
    const auto* locale=image.At(base.binding.sites[DefaultLocale].rva,738);LONG displacement=0;memcpy(&displacement,locale+0x9c,4);
    const auto constant_rva=base.binding.sites[DefaultLocale].rva+0xa0+displacement;
    BYTE* constant=const_cast<BYTE*>(image.At(constant_rva,12));const BYTE constant_saved=*constant;*constant^=1;
    check(!Resolve(image,true,true,result),"changed referenced NLS constant rejected");*constant=constant_saved;
    bool version_tested=false,pdb_tested=false;
    for(ULONG si=0;si<image.section_count;si++){
        const auto& section=image.sections[si];
        if(!memcmp(section.name,".rsrc",6)){
            const BYTE marker[]={0xbd,0x04,0xef,0xfe};auto begin=data.begin()+section.raw,end=begin+section.raw_size;
            auto found=std::search(begin,end,marker,marker+4);
            if(found!=end&&end-found>=12){
                BYTE* metadata=&*found+8;BYTE backup[4];memcpy(backup,metadata,4);metadata[0]^=0x7f;version_tested=true;
                check(Resolve(image,true,true,result)&&result.binding.match==EngineReuse,"resource version changes are packaging metadata only");
                data[target_offset+16]^=1;check(!Resolve(image,true,true,result),"forged version cannot authorize a changed object layout");data[target_offset+16]^=1;
                memcpy(metadata,backup,4);
            }
        }
        if(!memcmp(section.name,".rdata",7)){
            const BYTE marker[]={'R','S','D','S'};auto begin=data.begin()+section.raw,end=begin+section.raw_size;
            auto found=std::search(begin,end,marker,marker+4);
            if(found!=end&&end-found>=24){
                BYTE* metadata=&*found+4;*metadata^=1;pdb_tested=true;
                check(Resolve(image,true,true,result)&&result.binding.match==AbiResolved,"PDB identity alone does not determine compatibility");
                data[target_offset+16]^=1;check(!Resolve(image,true,true,result),"forged PDB identity cannot authorize a changed object layout");data[target_offset+16]^=1;*metadata^=1;
            }
        }
    }
    check(version_tested&&pdb_tested,"version and RSDS negative fixtures exercised");
    const auto* capture=image.At(base.binding.sites[NewString].rva,1);const size_t capture_offset=capture-data.data();const BYTE start=data[capture_offset];data[capture_offset]^=1;
    check(Resolve(image,false,true,result)&&!result.binding.capture_ready,"core readiness independent of optional capture");
    check(!Resolve(image,true,true,result)&&result.failure==CaptureUnavailable,"requested incomplete capture is rejected");data[capture_offset]=start;
    const BYTE* dir=image.data+image.pe+24+112+3*8;ULONG rva=0,bytes=0;memcpy(&rva,dir,4);memcpy(&bytes,dir+4,4);const BYTE* table=image.At(rva,bytes);
    bool tested=false;
    for(ULONG i=0;table&&i<bytes;i+=12){ULONG first=0,last=0;memcpy(&first,table+i,4);memcpy(&last,table+i+4,4);
        if(first==base.binding.sites[PublicLocale].rva||last-first!=89)continue;const BYTE* destination=image.At(first,89);if(!destination)continue;
        const size_t offset=destination-data.data();std::vector<BYTE> backup(data.begin()+offset,data.begin()+offset+89);
        memcpy(data.data()+offset,target,89);tested=true;
        check(!Resolve(image,true,true,result)&&result.failure==AmbiguousSite,"multiple complete-function matches rejected");
        memcpy(data.data()+offset,backup.data(),89);break;
    }
    check(tested,"ambiguity fixture exercised");
    std::cout<<"{\"passed\":"<<(failures.empty()?"true":"false")<<",\"checks\":"<<checks<<",\"failures\":[";
    bool first=true;for(const auto& f:failures){if(!first)std::cout<<',';first=false;std::cout<<'"'<<f<<'"';}std::cout<<"]}\n";return failures.empty()?0:1;
}
