import {mergeChapters} from './matcher.mjs';
export class MangaUpdater {
  constructor({store,sources,clock=()=>new Date()}){this.store=store;this.sources=sources;this.clock=clock;}
  async runDue({limit=25}={}){
    const jobs=await this.store.dueTrackedManga(this.clock(),limit);
    const results=[];for(const job of jobs){try{results.push(await this.updateOne(job));}catch(error){
      await this.store.markFailure(job.id,{message:safeMessage(error),retryAt:backoff(job.failures??0)});}}
    return results;
  }
  async updateOne(job){
    const releases=[];for(const mapping of job.sourceMappings){const source=this.sources.get(mapping.sourceId);
      if(!source?.capabilities.updates)continue;try{releases.push(...await source.getChapters(mapping.sourceMangaId));}
      catch(error){await this.store.recordSourceHealth(mapping.sourceId,false,safeMessage(error));}}
    const chapters=mergeChapters(releases);await this.store.commitCanonicalUpdate(job.id,chapters,{
      checkedAt:this.clock(),nextCheckAt:nextCheck(job,chapters,this.clock())});return {id:job.id,chapters:chapters.length};
  }
}
function nextCheck(job,chapters,now){if(job.status==='completed')return new Date(now.getTime()+30*24*60*60_000);
  const base=job.failures?Math.min(6*60,20*2**job.failures):20;return new Date(now.getTime()+base*60_000);}
function backoff(failures){return new Date(Date.now()+Math.min(6*60,2**failures*5)*60_000);}
function safeMessage(error){return error instanceof Error?error.message.slice(0,180):'Update failed';}
