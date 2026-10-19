import Foundation
@main struct CacheCleanupCheck {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:"/private/tmp/binge-cleanup-check-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let store=IPadCacheStore(root:root)
  let source=AddonStream(infoHash:String(repeating:"a",count:40),fileIdx:0)
  let lease=store.acquire(source);lease.workerFinished=false
  let payload=lease.folder.appendingPathComponent("payload.bin")
  try Data("first".utf8).write(to:payload)
  store.retire(lease)
  precondition(FileManager.default.fileExists(atPath:payload.path))
  store.workerEnded(lease)
  precondition(!FileManager.default.fileExists(atPath:lease.folder.path))
  let file=root.appendingPathComponent("reused.bin")
  try Data("old".utf8).write(to:file)
  VideoCacheCleanup.remove(file)
  try Data("new".utf8).write(to:file)
  try await Task.sleep(for:.milliseconds(500))
  let data=try Data(contentsOf:file)
  precondition(data==Data("new".utf8))
  let next=store.acquire(source)
  precondition(next.folder != lease.folder)
  precondition(FileManager.default.fileExists(atPath:next.folder.path))
  print("PASS: active worker cache retained, deferred retired cache removal, reused pathname protected, new lease unaffected")
 }
}
