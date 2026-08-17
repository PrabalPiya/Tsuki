const normalize=value=>value.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]/g,'');
export function matchManga(canonical,candidate){
  const sharedIds=Object.entries(canonical.externalIds??{}).some(([provider,id])=>id&&candidate.externalIds?.[provider]===id);
  if(sharedIds)return {matched:true,confidence:1,reasons:['trusted external id']};
  const titles=new Set([canonical.title,...canonical.aliases??[]].map(normalize));
  const titleMatch=[candidate.title,...candidate.aliases??[]].some(title=>titles.has(normalize(title)));
  const authorMatch=canonical.author&&candidate.author&&normalize(canonical.author)===normalize(candidate.author);
  const yearMatch=!canonical.year||!candidate.year||Math.abs(canonical.year-candidate.year)<=1;
  const matched=Boolean(titleMatch&&authorMatch&&yearMatch);
  return {matched,confidence:matched ? .86 : 0,reasons:[titleMatch&&'exact normalized title',authorMatch&&'author',yearMatch&&'year'].filter(Boolean)};
}
export function chapterKey(chapter){
  if(!Number.isFinite(chapter.number))return `special:${normalize(chapter.title??chapter.sourceId)}`;
  return `number:${chapter.number}`;
}
export function mergeChapters(chapters){
  const canonical=new Map();
  for(const chapter of chapters){if(chapter.language!=='en')continue;const key=chapterKey(chapter);const existing=canonical.get(key);
    canonical.set(key,existing?{...existing,sourceCopies:[...existing.sourceCopies,chapter]}:
      {id:key,number:chapter.number,title:chapter.title,sourceCopies:[chapter],publishedAt:chapter.publishedAt});}
  return [...canonical.values()].sort((a,b)=>(a.number??Infinity)-(b.number??Infinity));
}
