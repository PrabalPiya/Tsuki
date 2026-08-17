import http from 'node:http';
import {initializeApp,applicationDefault} from 'firebase-admin/app';
import {getAuth} from 'firebase-admin/auth';
import {getAppCheck} from 'firebase-admin/app-check';
import {getFirestore} from 'firebase-admin/firestore';
import {RateLimiter} from './rate_limiter.mjs';
initializeApp({credential:applicationDefault()});
const limiter=new RateLimiter();
async function authorize(request){
  const bearer=request.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
  const appCheck=request.headers['x-firebase-appcheck'];
  if(!bearer||!appCheck)throw new Error('Unauthorized');
  const [user]=await Promise.all([getAuth().verifyIdToken(bearer),getAppCheck().verifyToken(appCheck)]);
  if(user.appAccess!==true)throw new Error('Forbidden');
  const ip=request.socket.remoteAddress??'unknown';if(!limiter.consume(`uid:${user.uid}`)||!limiter.consume(`ip:${ip}`))throw new Error('Rate limited');
  return user;
}
export function createServer({search=async()=>[]}={}){
  return http.createServer(async(request,response)=>{
    response.setHeader('content-type','application/json');try{
      if(request.method==='GET'&&request.url==='/health'){response.end(JSON.stringify({ok:true}));return;}
      if(request.method==='GET'&&request.url?.startsWith('/v1/search?')){await authorize(request);const query=new URL(request.url,'https://local').searchParams.get('q')??'';
        if(query.length<2||query.length>100)throw new Error('Invalid query');const data=await search(query);response.end(JSON.stringify({data}));return;}
      if(request.method==='DELETE'&&request.url==='/v1/account'){const user=await authorize(request);const db=getFirestore();
        await db.recursiveDelete(db.collection('users').doc(user.uid));await getAuth().deleteUser(user.uid);
        response.end(JSON.stringify({deleted:true}));return;}
      response.statusCode=404;response.end(JSON.stringify({error:'Not found'}));
    }catch(error){const message=error instanceof Error?error.message:'Request failed';response.statusCode=
      message==='Unauthorized'?401:message==='Forbidden'?403:message==='Rate limited'?429:400;response.end(JSON.stringify({error:message}));}
  });
}
if(process.argv[1]===new URL(import.meta.url).pathname){createServer().listen(Number(process.env.PORT??8080),'127.0.0.1');}
