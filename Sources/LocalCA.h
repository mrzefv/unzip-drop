//
//  LocalCA.h — on-device root CA + leaf issuer (implemented in LocalCA.mm).
//
#import <Foundation/Foundation.h>

@interface LocalCA : NSObject
+ (NSDictionary<NSString *, NSString *> * _Nullable)generateRootCAWithCommonName:(NSString * _Nonnull)cn
                                                                     validYears:(int)years;
+ (NSDictionary<NSString *, NSString *> * _Nullable)issueLeafForHost:(NSString * _Nonnull)host
                                                          rootCertPEM:(NSString * _Nonnull)rootCertPEM
                                                           rootKeyPEM:(NSString * _Nonnull)rootKeyPEM
                                                           validYears:(int)years;
+ (NSDictionary<NSString *, NSString *> * _Nullable)issueLeafForHost:(NSString * _Nonnull)host
                                                          rootCertPEM:(NSString * _Nonnull)rootCertPEM
                                                           rootKeyPEM:(NSString * _Nonnull)rootKeyPEM
                                                            validDays:(int)days;
@end
