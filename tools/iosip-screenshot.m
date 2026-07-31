#import <UIKit/UIKit.h>

extern CGImageRef UIGetScreenImage(void);

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2)
            return 2;
        CGImageRef image = UIGetScreenImage();
        if (!image)
            return 1;
        NSData *data = UIImagePNGRepresentation(
            [UIImage imageWithCGImage:image]);
        return [data writeToFile:@(argv[1]) atomically:YES] ? 0 : 1;
    }
}
