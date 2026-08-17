import test from 'node:test';import assert from 'node:assert/strict';import {ChapterResolver} from '../src/resolver.mjs';
test('failed preferred source silently falls back',async()=>{
  const adapters=[{id:'a',capabilities:{pages:true},getChapterPages:async()=>{throw new Error('down');}},
    {id:'b',capabilities:{pages:true},getChapterPages:async()=>['https://cdn.example/page.jpg']}];
  const resolver=new ChapterResolver(adapters);const pages=await resolver.pages([
    {sourceId:'a',sourceChapterId:'1',language:'en',complete:true,quality:1},
    {sourceId:'b',sourceChapterId:'2',language:'en',complete:true,quality:.5}]);
  assert.deepEqual(pages,['https://cdn.example/page.jpg']);
});
