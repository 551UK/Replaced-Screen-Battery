#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *const kSocketPath=@"/var/jb/var/mobile/551UK-ChargeRateTest-v052/chargerated.sock";
static NSString *request(NSString *command) {
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0)return [NSString stringWithFormat:@"ERR socket %d",errno];
    struct sockaddr_un sa;memset(&sa,0,sizeof(sa));sa.sun_family=AF_UNIX;
    strlcpy(sa.sun_path,[kSocketPath UTF8String],sizeof(sa.sun_path));
    struct timeval tv={4,0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,sizeof(tv));
    if(connect(fd,(struct sockaddr *)&sa,sizeof(sa))!=0) {
        int e=errno;close(fd);return [NSString stringWithFormat:@"ERR helper offline (%d)",e];
    }
    NSData *cmd=[[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if(write(fd,cmd.bytes,cmd.length)!=(ssize_t)cmd.length){close(fd);return @"ERR command send failed";}
    shutdown(fd,SHUT_WR);
    NSMutableData *out=[NSMutableData data];char buf[2048];ssize_t n;
    while((n=read(fd,buf,sizeof(buf)))>0&&out.length<64000)[out appendBytes:buf length:n];
    close(fd);
    NSString *response=[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    return response?:@"ERR invalid helper response";
}
static NSString *reading(NSDictionary *d,NSString *key,NSString *suffix) {
    id v=d[key];
    if(!v||v==[NSNull null]||![v respondsToSelector:@selector(doubleValue)])return @"—";
    return [NSString stringWithFormat:@"%.2f%@",[v doubleValue],suffix?:@""];
}
static NSString *watts(NSDictionary*d,NSString*k,NSInteger divide) {
    id v=d[k];
    if(![v isKindOfClass:NSNumber.class])return @"—";
    return [NSString stringWithFormat:@"%.2f W",[v doubleValue]/divide];
}
static UIColor *rgb(CGFloat r,CGFloat g,CGFloat b){return [UIColor colorWithRed:r green:g blue:b alpha:1];}
@interface ChargeViewController:UIViewController
@property(nonatomic,strong)UIScrollView *scroll;
@property(nonatomic,strong)UILabel *statusLabel,*chargerLabel,*inputLabel,*batteryLabel,*usbLabel,*effectiveLabel,*capLabel,*batteryPctLabel;
@property(nonatomic,strong)UISlider *currentSlider;
@property(nonatomic,strong)UISwitch *enableSwitch;
@property(nonatomic,strong)UITextView *logView;
@property(nonatomic,strong)UIButton *applyButton,*restoreButton,*logButton;
@property(nonatomic,strong)NSTimer *timer;
@property(nonatomic,assign)BOOL busy;
@end
@implementation ChargeViewController
- (UILabel*)makeLabel:(NSString*)text font:(CGFloat)sz y:(CGFloat)y color:(UIColor*)col {
    UILabel *lab=[[UILabel alloc]initWithFrame:CGRectMake(18,y,330,44)];
    lab.text=text;lab.numberOfLines=0;lab.textColor=col;lab.font=[UIFont systemFontOfSize:sz weight:UIFontWeightMedium];
    [self.scroll addSubview:lab];return lab;
}
- (UIButton*)makeButton:(NSString*)title y:(CGFloat)y color:(UIColor*)color action:(SEL)sel{
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.frame=CGRectMake(18,y,330,48);
    button.backgroundColor=color;button.layer.cornerRadius=12;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [button addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:button];return button;
}
- (void)viewDidLoad{
    [super viewDidLoad];self.view.backgroundColor=rgb(.05,.075,.12);
    self.scroll=[[UIScrollView alloc]initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];
    UIColor *white=rgb(.95,.97,1),*mute=rgb(.6,.68,.79),*cyan=rgb(.40,.82,1);
    [self makeLabel:@"USB Charge Control" font:27 y:28 color:white];
    [self makeLabel:@"551UK  •  Dopamine rootless  •  iOS 16" font:12 y:69 color:mute];
    self.statusLabel=[self makeLabel:@"Connecting to charging controller…" font:13 y:107 color:cyan];
    self.statusLabel.frame=CGRectMake(18,107,330,48);
    [self makeLabel:@"CHARGING DATA" font:13 y:161 color:cyan];
    self.chargerLabel=[self makeLabel:@"Charger Rating: —" font:16 y:193 color:white];
    self.inputLabel=[self makeLabel:@"Input Rail: — W  |  — mA" font:18 y:230 color:white];
    self.batteryLabel=[self makeLabel:@"Battery: — W  |  — mA" font:18 y:270 color:white];
    self.batteryPctLabel=[self makeLabel:@"Battery: —" font:15 y:306 color:mute];
    self.usbLabel=[self makeLabel:@"USB negotiated voltage: —" font:15 y:342 color:mute];
    self.effectiveLabel=[self makeLabel:@"Current USB limit: —" font:15 y:377 color:white];
    [self makeLabel:@"CHARGING CURRENT CAP" font:13 y:424 color:cyan];
    self.capLabel=[self makeLabel:@"Selected: 1000mA" font:18 y:461 color:white];
    self.currentSlider=[[UISlider alloc]initWithFrame:CGRectMake(18,510,330,34)];
    self.currentSlider.minimumValue=500;self.currentSlider.maximumValue=2400;self.currentSlider.value=1000;
    [self.currentSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.currentSlider addTarget:self action:@selector(sliderDone:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    [self.scroll addSubview:self.currentSlider];
    [self makeLabel:@"500mA                             2400mA" font:12 y:542 color:mute];
    [self makeLabel:@"Enable current limit" font:17 y:574 color:white];
    self.enableSwitch=[[UISwitch alloc]initWithFrame:CGRectMake(274,580,55,36)];
    [self.enableSwitch addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:self.enableSwitch];
    self.applyButton=[self makeButton:@"Apply selected current" y:635 color:rgb(.08,.45,.77) action:@selector(applyTapped:)];
    self.restoreButton=[self makeButton:@"Restore normal charging" y:697 color:rgb(.39,.20,.23) action:@selector(restoreTapped:)];
    self.logButton=[self makeButton:@"Refresh & copy diagnostics" y:767 color:rgb(.17,.22,.34) action:@selector(copyLog:)];
    [self makeLabel:@"Input Rail and Battery use iOS telemetry; readings may lag. Charger Rating is reported by iOS, not measured at the wall. No CPU/GPU throttling." font:12 y:829 color:mute].frame=CGRectMake(18,829,330,85);
    self.logView=[[UITextView alloc]initWithFrame:CGRectMake(18,922,330,180)];
    self.logView.backgroundColor=rgb(.095,.13,.20);self.logView.textColor=white;
    self.logView.font=[UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];self.logView.editable=NO;
    self.logView.layer.cornerRadius=12;self.logView.text=@"Diagnostics will appear here.";
    [self.scroll addSubview:self.logView];self.scroll.contentSize=CGSizeMake(365,1130);
    NSInteger saved=[[NSUserDefaults standardUserDefaults]integerForKey:@"selectedCurrent"];
    if(saved>=500&&saved<=2400)self.currentSlider.value=saved;
    [self sliderChanged:self.currentSlider];[self refresh:nil];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}
- (void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];
    CGFloat w=self.view.bounds.size.width, usable=w-36;
    for(UIView *v in self.scroll.subviews){
        if(v==self.enableSwitch){v.frame=CGRectMake(w-84,v.frame.origin.y,55,36);continue;}
        CGRect f=v.frame;f.size.width=usable;v.frame=f;
    }
    CGRect s=self.currentSlider.frame;s.size.width=usable;self.currentSlider.frame=s;
    self.scroll.contentSize=CGSizeMake(w,1130);
}
- (NSInteger)selectedMA{return (NSInteger)(roundf(self.currentSlider.value/100.0f)*100);}
- (void)sliderChanged:(id)sender{
    NSInteger ma=[self selectedMA];
    self.capLabel.text=[NSString stringWithFormat:@"Selected: %ld mA",(long)ma];
    (void)sender;
}
- (void)sliderDone:(id)sender{
    NSInteger ma=[self selectedMA];self.currentSlider.value=ma;
    [[NSUserDefaults standardUserDefaults]setInteger:ma forKey:@"selectedCurrent"];
    if(self.enableSwitch.isOn)[self applyTapped:sender];
}
- (void)presentStatus:(NSString*)message ok:(BOOL)ok{
    self.statusLabel.text=message;
    self.statusLabel.textColor=ok?rgb(.38,.87,.65):rgb(.98,.55,.49);
}
- (void)refresh:(id)sender{
    (void)sender;
    if(self.busy)return;
    NSString *raw=request(@"STATE");
    NSData *data=[raw dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *d=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![d isKindOfClass:NSDictionary.class]){[self presentStatus:@"Controller offline: open diagnostics if needed." ok:NO];return;}
    self.chargerLabel.text=[NSString stringWithFormat:@"Charger Rating: %@",watts(d,@"adapter_w",1)];
    NSNumber *railMA=[d[@"system_ma"] isKindOfClass:NSNumber.class]?d[@"system_ma"]:nil;
    NSString *railMAtext=railMA?[NSString stringWithFormat:@"%.0f mA",railMA.doubleValue]:@"— mA";
    self.inputLabel.text=[NSString stringWithFormat:@"Input Rail: %@  |  %@",watts(d,@"system_mw",1000),railMAtext];
    NSNumber *mv=[d[@"battery_mv"] isKindOfClass:NSNumber.class]?d[@"battery_mv"]:nil;
    NSNumber *ma=[d[@"battery_ma"] isKindOfClass:NSNumber.class]?d[@"battery_ma"]:nil;
    NSString *batteryW=mv&&ma?[NSString stringWithFormat:@"%.2f W",mv.doubleValue*ma.doubleValue/1000000.0]:@"— W";
    NSString *batteryMA=ma?[NSString stringWithFormat:@"%.0f mA",ma.doubleValue]:@"— mA";
    self.batteryLabel.text=[NSString stringWithFormat:@"Battery: %@  |  %@",batteryW,batteryMA];
    self.batteryPctLabel.text=[NSString stringWithFormat:@"Battery: %@%%   |   Charging: %@",reading(d,@"battery_percent",@""),[d[@"charging"] respondsToSelector:@selector(intValue)]&&[d[@"charging"]intValue]==1?@"Yes":@"No"];
    self.usbLabel.text=[NSString stringWithFormat:@"USB voltage: %@",[d[@"usb_mv"] isKindOfClass:NSNumber.class]?[NSString stringWithFormat:@"%.2f V",[d[@"usb_mv"]doubleValue]/1000.0]:@"—"];
    self.effectiveLabel.text=[NSString stringWithFormat:@"Effective USB current cap: %@ mA",reading(d,@"usb_ma",@"")];
    BOOL enabled=[d[@"enabled"] respondsToSelector:@selector(boolValue)]&&[d[@"enabled"] boolValue];
    [self.enableSwitch setOn:enabled animated:NO];
    NSString *msg=[d[@"message"] isKindOfClass:NSString.class]?d[@"message"]:@"";
    [self presentStatus:msg.length?msg:(enabled?@"USB current cap ACTIVE":@"Normal charging / no cap active") ok:msg.length==0];
}
- (void)sendAction:(NSString*)cmd success:(NSString*)name{
    if(self.busy)return;self.busy=YES;[self presentStatus:[NSString stringWithFormat:@"%@…",name] ok:YES];
    NSString *raw=request(cmd);
    BOOL ok=[raw hasPrefix:@"OK "];NSString *msg=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.busy=NO;[self refresh:nil];[self presentStatus:ok?([cmd isEqualToString:@"RESTORE"]?@"USB limit released. Check Input Rail: actual recovery is unverified.":[NSString stringWithFormat:@"%@ applied",name]):[NSString stringWithFormat:@"Failed: %@",msg] ok:ok];
    if(!ok)self.enableSwitch.on=[cmd hasPrefix:@"ENABLE"]?NO:self.enableSwitch.on;
}
- (void)toggleChanged:(UISwitch*)sender{
    if(sender.isOn)[self sendAction:[NSString stringWithFormat:@"ENABLE %ld",(long)[self selectedMA]] success:@"Current cap"];
    else [self sendAction:@"RESTORE" success:@"Normal charging"];
}
- (void)applyTapped:(id)sender{
    (void)sender;
    [self sendAction:[NSString stringWithFormat:@"ENABLE %ld",(long)[self selectedMA]] success:@"Current cap"];
}
- (void)restoreTapped:(id)sender{(void)sender;[self sendAction:@"RESTORE" success:@"Normal charging"];}
- (void)copyLog:(id)sender{
    (void)sender;NSString *log=request(@"LOG");
    if([log hasPrefix:@"ERR "]){[self presentStatus:log ok:NO];return;}
    self.logView.text=log;
    UIPasteboard.generalPasteboard.string=log;
    [self presentStatus:@"Diagnostics copied. Paste into ChatGPT." ok:YES];
}
- (void)dealloc{[self.timer invalidate];}
@end
@interface ChargeAppDelegate:UIResponder <UIApplicationDelegate>
@property(nonatomic,strong)UIWindow *window;
@end
@implementation ChargeAppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts{
    (void)app;(void)opts;
    self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[ChargeViewController new];
    [self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ChargeAppDelegate.class));}}
