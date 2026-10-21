#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL MXMenuVisibilityAvailable(void);
void MXMenuVisibilityActivate(NSArray<NSNumber *> *systemItems, NSArray<NSString *> *bundles,
                             void (^completion)(id _Nullable handle, NSError * _Nullable error));
void MXMenuVisibilityInvalidate(id handle);
NS_ASSUME_NONNULL_END
