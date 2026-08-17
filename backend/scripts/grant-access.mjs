import {applicationDefault,initializeApp} from 'firebase-admin/app';
import {getAuth} from 'firebase-admin/auth';
const identifier=process.argv[2];if(!identifier){console.error('Usage: node scripts/grant-access.mjs <uid-or-email>');process.exit(2);}
initializeApp({credential:applicationDefault()});const auth=getAuth();
const user=identifier.includes('@')?await auth.getUserByEmail(identifier):await auth.getUser(identifier);
await auth.setCustomUserClaims(user.uid,{...user.customClaims,appAccess:true});
console.log(`Granted appAccess to UID ${user.uid}. The user must refresh their ID token.`);
