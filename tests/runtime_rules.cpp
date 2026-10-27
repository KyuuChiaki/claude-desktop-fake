#include "time_core.h"
#include "sha256.h"
#include <iostream>
#include <string>
#include <vector>
#include <cstring>
namespace {
unsigned checks=0;std::vector<std::string> failures;
void Check(bool value,const std::string& name){++checks;if(!value)failures.push_back(name);}
std::string Hex(const BYTE* data){constexpr char digits[]="0123456789abcdef";std::string result;for(unsigned i=0;i<32;i++){result+=digits[data[i]>>4];result+=digits[data[i]&15];}return result;}
std::string Config(const std::string& region="us",const std::string& runtime="\"enabled\":true,\"unknownVersionPolicy\":\"block\",\"captureEnabled\":false"){
    return "{\"schemaVersion\":3,\"time\":{\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":3600},\"locale\":{\"enabled\":true,\"formatLocale\":\"de-DE\",\"uiLanguage\":\"ja-JP\"},\"region\":{\"enabled\":true,\"homeRegion\":\""+region+"\"},\"runtime\":{"+runtime+"}}";
}
}
int main(){
    for(const auto& pair:{std::pair<const char*,const char*>("","e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),{"abc","ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq","248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"}}){
        cdf::Sha256 hash;hash.Init();hash.Update(reinterpret_cast<const BYTE*>(pair.first),std::strlen(pair.first));BYTE bytes[32];hash.Finish(bytes);Check(Hex(bytes)==pair.second,"SHA-256 published vector");
    }
    cdf::Sha256 stream;stream.Init();for(unsigned i=0;i<1000000;i++){const BYTE a='a';stream.Update(&a,1);}BYTE digest[32];stream.Finish(digest);Check(Hex(digest)=="cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0","SHA-256 incremental million bytes");
    cdf::Config config{};DWORD error=0;
    for(const std::string region:{"us","DE","JP","IN","GB","CN"}){
        const std::string json=Config(region);Check(cdf::ParseConfig(json.data(),static_cast<ULONG>(json.size()),config,error),"schema3 parses "+region);
        Check(config.region.home_region[0]>=L'A'&&config.region.home_region[0]<=L'Z',"uppercase region "+region);
        Check(cdf::ValidateRegion(config.region,error),"concrete installed region "+region);
        WCHAR reference[16]{};GetGeoInfoEx(config.region.home_region,GEO_ID,reference,16);Check(config.region.geo_id==std::wcstol(reference,nullptr,10),"GEOID oracle "+region);
    }
    for(const std::string region:{"EU","ZZ","001","U","USA","us-x","12"}){
        const std::string json=Config(region);const bool parsed=cdf::ParseConfig(json.data(),static_cast<ULONG>(json.size()),config,error);
        Check(!parsed||!cdf::ValidateRegion(config.region,error),"invalid or macro region "+region);
    }
    for(const std::string runtime:{"\"enabled\":true,\"unknownVersionPolicy\":\"passthrough\",\"captureEnabled\":true","\"captureEnabled\":false,\"enabled\":false,\"unknownVersionPolicy\":\"block\""}){
        const auto json=Config("US",runtime);Check(cdf::ParseConfig(json.data(),static_cast<ULONG>(json.size()),config,error),"runtime group ordering and policies");
    }
    for(const std::string runtime:{"\"enabled\":true,\"unknownVersionPolicy\":\"allow\",\"captureEnabled\":false","\"enabled\":true,\"unknownVersionPolicy\":\"Block\",\"captureEnabled\":false","\"enabled\":true,\"unknownVersionPolicy\":true,\"captureEnabled\":false","\"enabled\":true,\"enabled\":false,\"captureEnabled\":false","\"enabled\":true,\"unknownVersionPolicy\":\"block\"","\"enabled\":true,\"unknownVersionPolicy\":\"block\",\"captureEnabled\":1","\"enabled\":true,\"unknownVersionPolicy\":\"block\",\"captureEnabled\":false,\"extra\":0"}){
        const auto json=Config("US",runtime);Check(!cdf::ParseConfig(json.data(),static_cast<ULONG>(json.size()),config,error),"strict runtime fields");
    }
    const std::string v1="{\"schemaVersion\":1,\"enabled\":true,\"timeZoneId\":\"UTC\",\"utcOffsetSeconds\":0}";
    Check(cdf::ParseConfig(v1.data(),static_cast<ULONG>(v1.size()),config,error)&&!config.region.enabled&&!config.runtime.enabled,"schema1 leaves stage5 disabled");
    std::cout<<"{\"passed\":"<<(failures.empty()?"true":"false")<<",\"checks\":"<<checks<<",\"failures\":[";bool first=true;for(const auto& name:failures){if(!first)std::cout<<',';first=false;std::cout<<'\"'<<name<<'\"';}std::cout<<"]}\n";return failures.empty()?0:1;
}
