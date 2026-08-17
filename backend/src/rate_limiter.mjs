export class RateLimiter {
  constructor({capacity=30,refillPerSecond=.5}={}){this.capacity=capacity;this.refill=refillPerSecond;this.buckets=new Map();}
  consume(key,cost=1){const now=Date.now();const old=this.buckets.get(key)??{tokens:this.capacity,at:now};
    const tokens=Math.min(this.capacity,old.tokens+(now-old.at)/1000*this.refill);
    if(tokens<cost){this.buckets.set(key,{tokens,at:now});return false;}this.buckets.set(key,{tokens:tokens-cost,at:now});return true;}
}
