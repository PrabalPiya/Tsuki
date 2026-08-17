import test from 'node:test';import assert from 'node:assert/strict';
import {matchManga,mergeChapters} from '../src/matcher.mjs';
test('trusted IDs match and uncertain titles remain separate',()=>{
  assert.equal(matchManga({title:'A',externalIds:{anilist:1}},{title:'Other',externalIds:{anilist:1}}).matched,true);
  assert.equal(matchManga({title:'Blue',author:'A',year:2020},{title:'Blue',author:'B',year:2020}).matched,false);
});
test('English duplicate chapters collapse while decimals remain',()=>{
  const result=mergeChapters([{number:10,language:'en',sourceId:'a'},{number:10,language:'en',sourceId:'b'},
    {number:10.5,language:'en',sourceId:'a'},{number:11,language:'ja',sourceId:'a'}]);
  assert.equal(result.length,2);assert.equal(result[0].sourceCopies.length,2);assert.equal(result[1].number,10.5);
});
