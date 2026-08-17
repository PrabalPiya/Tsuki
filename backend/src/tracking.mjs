// Call this from the deployment platform's bookmark create/delete trigger.
// Counting occurs from authoritative user records; clients never provide totals.
export async function reconcileTracking(store,mangaId){
  const followerCount=await store.countFollowers(mangaId);
  await store.transaction(async transaction=>{
    const current=await transaction.getTrackedManga(mangaId);
    await transaction.setTrackedManga(mangaId,{
      ...(current??{}),followerCount,active:followerCount>0,
      nextCheckAt:followerCount>0?(current?.nextCheckAt??new Date()):null,
      updatedAt:new Date(),
    });
  });
  return followerCount;
}
