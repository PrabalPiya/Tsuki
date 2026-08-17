import dns from 'node:dns/promises';
import net from 'node:net';
const blockedHosts=new Set(['localhost','metadata.google.internal','169.254.169.254']);
export async function validateUpstreamUrl(input,{allowedHosts,maxRedirects=3}={}){
  let url=new URL(input);for(let redirect=0;redirect<=maxRedirects;redirect++){
    if(url.protocol!=='https:'||url.username||url.password||blockedHosts.has(url.hostname))throw new Error('Unsafe upstream URL');
    if(allowedHosts&&!allowedHosts.has(url.hostname))throw new Error('Host is not approved');
    const answers=await dns.lookup(url.hostname,{all:true});if(answers.some(a=>isPrivate(a.address)))throw new Error('Private address rejected');
    return url;
  }throw new Error('Too many redirects');
}
export async function safeImageFetch(input,{allowedHosts,maxBytes=25*1024*1024}){
  let url=await validateUpstreamUrl(input,{allowedHosts});for(let redirects=0;redirects<4;redirects++){
    const response=await fetch(url,{redirect:'manual',signal:AbortSignal.timeout(12_000)});
    if(response.status>=300&&response.status<400){const location=response.headers.get('location');if(!location)throw new Error('Invalid redirect');
      url=await validateUpstreamUrl(new URL(location,url),{allowedHosts});continue;}
    if(!response.ok)throw new Error('Upstream failed');const type=response.headers.get('content-type')??'';
    if(!type.startsWith('image/'))throw new Error('Unexpected MIME type');const length=Number(response.headers.get('content-length')??0);
    if(length>maxBytes)throw new Error('Image too large');return response;
  }throw new Error('Too many redirects');
}
function isPrivate(address){if(net.isIPv4(address)){const [a,b]=address.split('.').map(Number);
    return a===10||a===127||a===0||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&b===168);}
  const value=address.toLowerCase();return value==='::1'||value.startsWith('fc')||value.startsWith('fd')||value.startsWith('fe80:')||value==='::';}
