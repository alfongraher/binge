#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TorrentProof : NSObject
- (BOOL)startWithFixture:(NSString *)fixture cache:(NSString *)cache error:(NSString * _Nullable * _Nullable)error;
- (BOOL)startExternalMagnet:(NSString *)magnet cache:(NSString *)cache error:(NSString * _Nullable * _Nullable)error;
- (BOOL)startMagnet:(NSString *)magnet cache:(NSString *)cache fileIndex:(int)index error:(NSString * _Nullable * _Nullable)error;
- (long long)videoSize;
- (nullable NSString *)selectedFilePath;
- (BOOL)selectedFileComplete;
- (nullable NSData *)readVerifiedVideoAt:(long long)offset length:(int)length;
- (void)refreshDiscovery;
- (void)setDownloadLimit:(int)bytesPerSecond;
- (void)prepareStreaming;
- (BOOL)selectFile:(int)index;
- (long long)fileSize:(int)index;
- (BOOL)prefetchFile:(int)index;
- (NSString *)snapshot;
- (void)selectNextFile;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
