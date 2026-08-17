import test from 'node:test';import assert from 'node:assert/strict';import {validateUpstreamUrl} from '../src/url_policy.mjs';
test('rejects non-https and metadata hosts',async()=>{
  await assert.rejects(()=>validateUpstreamUrl('file:///etc/passwd'));
  await assert.rejects(()=>validateUpstreamUrl('http://169.254.169.254/latest/meta-data'));
  await assert.rejects(()=>validateUpstreamUrl('https://user:pass@example.com/image.jpg'));
});
