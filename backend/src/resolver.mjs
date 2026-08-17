export class SourceHealth {
  #state=new Map();
  record(sourceId,success,latencyMs=0){const old=this.#state.get(sourceId)??{failures:0,latencyMs:500,penaltyUntil:0};
    const failures=success?Math.max(0,old.failures-1):old.failures+1;
    this.#state.set(sourceId,{failures,latencyMs:old.latencyMs*.75+latencyMs*.25,
      penaltyUntil:success?old.penaltyUntil:Date.now()+Math.min(30*60_000,2**failures*5_000)});}
  score(sourceId){const value=this.#state.get(sourceId);if(!value)return 1;
    return (Date.now()<value.penaltyUntil ? .45 : 1)-Math.min(.45,value.failures*.08)-Math.min(.15,value.latencyMs/20_000);}
}
export class ChapterResolver {
  constructor(adapters,health=new SourceHealth()){this.adapters=new Map(adapters.map(a=>[a.id,a]));this.health=health;}
  rank(copies){return copies.filter(c=>c.language==='en'&&c.complete!==false).sort((a,b)=>
    this.health.score(b.sourceId)+(.2*(b.quality??0))-this.health.score(a.sourceId)-(.2*(a.quality??0)));}
  async pages(copies){let lastError;for(const copy of this.rank(copies)){const source=this.adapters.get(copy.sourceId);if(!source?.capabilities.pages)continue;
      const started=Date.now();try{const pages=await source.getChapterPages(copy.sourceChapterId);validatePages(pages);
        this.health.record(copy.sourceId,true,Date.now()-started);return pages;}catch(error){lastError=error;this.health.record(copy.sourceId,false,Date.now()-started);}}
    throw new Error('Chapter unavailable right now.',{cause:lastError});}
}
function validatePages(pages){if(!Array.isArray(pages)||pages.length<1||pages.length>500)throw new Error('Invalid page list');
  for(const value of pages){const url=new URL(value);if(url.protocol!=='https:'||url.username||url.password)throw new Error('Unsafe page URL');}}
