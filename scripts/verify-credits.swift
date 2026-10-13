import Foundation
@main struct CreditsCheck {
 @MainActor static func main() throws {
  precondition(!CreditsTiming.reached(position:3419,duration:3600,type:"movie"))
  precondition(CreditsTiming.reached(position:3420,duration:3600,type:"movie"))
  precondition(!CreditsTiming.reached(position:2639,duration:2700,type:"series"))
  precondition(CreditsTiming.reached(position:2640,duration:2700,type:"series"))
  precondition(!CreditsTiming.reached(position:0,duration:0,type:"movie"))
  let defaults=UserDefaults(suiteName:"binge.credits.test."+UUID().uuidString)!
  let ipad=IPadHistory(defaults:defaults)
  let show=CatalogTitle(id:"show",type:"series",name:"Show")
  var first=IPadWatchContext(title:show);first.contentID="show:1:1"
  var next=first;next.contentID="show:1:2"
  let stream=AddonStream(infoHash:String(repeating:"a",count:40),fileIdx:1)
  ipad.save(first,stream:stream,position:2640,duration:2700)
  precondition(ipad.record(first)?.completed==true)
  ipad.queueNext(next,stream:stream)
  precondition(ipad.continuing.first?.context.contentID==next.contentID)
  precondition(ipad.record(next)?.completed==false && ipad.record(next)?.position==0)
  let file=URL(fileURLWithPath:"/private/tmp/credits-history-"+UUID().uuidString+".json")
  defer {try? FileManager.default.removeItem(at:file)}
  let mac=WatchHistory(file:file)
  let current=PlaybackSelection(title:"Show · E1",stream:stream,contentID:first.contentID,contentType:"series")
  let upcoming=PlaybackSelection(title:"Show · E2",stream:stream,contentID:next.contentID,contentType:"series")
  mac.record(current,position:2640,duration:2700);mac.queueNext(upcoming)
  precondition(mac.records.first(where:{$0.contentID==first.contentID})?.complete==true)
  precondition(mac.continueWatching.first?.contentID==next.contentID)
  print("PASS: bounded credits estimates, unknown duration, episode completion and next-episode continuation on Mac and iPad")
 }
}
