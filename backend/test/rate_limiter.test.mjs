import test from 'node:test';import assert from 'node:assert/strict';import {RateLimiter} from '../src/rate_limiter.mjs';
test('bounds expensive operations',()=>{const limiter=new RateLimiter({capacity:2,refillPerSecond:0});
  assert.equal(limiter.consume('u'),true);assert.equal(limiter.consume('u'),true);assert.equal(limiter.consume('u'),false);});
