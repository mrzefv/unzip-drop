//
//  unzip-drop-Bridging-Header.h
//  Exposes the zsign C/ObjC++ signing engine (Sources/zsign) to Swift.
//  zsign.hpp declares its entrypoints inside extern "C", so they import as
//  free functions: zsign(...), InjectDyLib(...), ChangeDylibPath(...),
//  ListDylibs(...), UninstallDylibs(...).
//

#ifndef unzip_drop_Bridging_Header_h
#define unzip_drop_Bridging_Header_h

#import "zsign/zsign.hpp"

#endif
