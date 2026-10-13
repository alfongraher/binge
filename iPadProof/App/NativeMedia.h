#import <Foundation/Foundation.h>
@class TorrentProof;
NS_ASSUME_NONNULL_BEGIN
@interface NativeMedia : NSObject
- (void)remuxInput:(NSString *)input output:(NSString *)output completion:(void (^)(NSString *result))completion NS_SWIFT_NAME(remux(input:output:completion:));
- (void)streamTorrent:(TorrentProof *)engine directory:(NSString *)directory completion:(void (^)(NSString *result))completion NS_SWIFT_NAME(stream(engine:directory:completion:));
- (void)streamTorrent:(TorrentProof *)engine directory:(NSString *)directory startAt:(double)seconds completion:(void (^)(NSString *result))completion NS_SWIFT_NAME(stream(engine:directory:startAt:completion:));
- (double)duration;
- (double)sourceOffset;
- (void)cancel;
- (NSString *)diagnostic;
@end
NS_ASSUME_NONNULL_END
