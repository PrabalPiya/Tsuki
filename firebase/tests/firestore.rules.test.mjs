import fs from 'node:fs/promises';
import {after, before, beforeEach, test} from 'node:test';
import assert from 'node:assert/strict';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {doc, getDoc, setDoc, serverTimestamp} from 'firebase/firestore';
let env;
before(async()=>{env=await initializeTestEnvironment({projectId:'quiet-reader-rules-test',
  firestore:{rules:await fs.readFile(new URL('../firestore.rules',import.meta.url),'utf8')}});});
beforeEach(()=>env.clearFirestore());after(()=>env.cleanup());
const authed=(uid,access=true)=>env.authenticatedContext(uid,access?{appAccess:true}:{}).firestore();
test('unauthenticated and no-claim reads fail',async()=>{
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(),'manga/a')));
  await assertFails(getDoc(doc(authed('a',false),'manga/a')));
});
test('canonical and internal writes fail',async()=>{
  await assertFails(setDoc(doc(authed('a'),'manga/a'),{title:'forged'}));
  await assertFails(setDoc(doc(authed('a'),'rankings/week'),{items:[]}));
  await assertFails(setDoc(doc(authed('a'),'trackedManga/a'),{followers:0}));
});
test('users are isolated',async()=>{
  await assertFails(getDoc(doc(authed('a'),'users/b/bookmarks/m')));
  await assertFails(setDoc(doc(authed('a'),'users/b/bookmarks/m'),{mangaId:'m',updatedAt:new Date()}));
});
test('owner can write bounded progress',async()=>{
  await assertSucceeds(setDoc(doc(authed('a'),'users/a/progress/m'),{mangaId:'m',chapterId:'c',pageIndex:1,
    relativeOffset:.2,chapterProgress:.4,openedChapterIds:['c'],updatedAt:serverTimestamp()}));
  await assertFails(setDoc(doc(authed('a'),'users/a/progress/m'),{mangaId:'m',chapterId:'c',pageIndex:-1,
    relativeOffset:4,chapterProgress:.4,openedChapterIds:['c'],updatedAt:serverTimestamp()}));
});
