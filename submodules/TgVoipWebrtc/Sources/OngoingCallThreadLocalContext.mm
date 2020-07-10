#import <TgVoip/OngoingCallThreadLocalContext.h>

#import "TgVoip.h"
#import "VideoMetalView.h"

using namespace TGVOIP_NAMESPACE;

@implementation OngoingCallConnectionDescriptionWebrtc

- (instancetype _Nonnull)initWithConnectionId:(int64_t)connectionId ip:(NSString * _Nonnull)ip ipv6:(NSString * _Nonnull)ipv6 port:(int32_t)port peerTag:(NSData * _Nonnull)peerTag {
    self = [super init];
    if (self != nil) {
        _connectionId = connectionId;
        _ip = ip;
        _ipv6 = ipv6;
        _port = port;
        _peerTag = peerTag;
    }
    return self;
}

@end

@interface OngoingCallThreadLocalContextVideoCapturer () {
    std::shared_ptr<TgVoipVideoCaptureInterface> _interface;
}

@end

@implementation OngoingCallThreadLocalContextVideoCapturer

- (instancetype _Nonnull)init {
    self = [super init];
    if (self != nil) {
        _interface = TgVoipVideoCaptureInterface::makeInstance();
    }
    return self;
}

- (void)switchVideoCamera {
    _interface->switchCamera();
}

- (void)setIsVideoEnabled:(bool)isVideoEnabled {
    _interface->setIsVideoEnabled(isVideoEnabled);
}

- (std::shared_ptr<TgVoipVideoCaptureInterface>)getInterface {
    return _interface;
}

- (void)makeOutgoingVideoView:(void (^_Nonnull)(OngoingCallThreadLocalContextWebrtcVideoView * _Nullable))completion {
    std::shared_ptr<TgVoipVideoCaptureInterface> interface = _interface;
    dispatch_async(dispatch_get_main_queue(), ^{
        VideoMetalView *remoteRenderer = [[VideoMetalView alloc] initWithFrame:CGRectZero];
        remoteRenderer.videoContentMode = UIViewContentModeScaleAspectFill;
        
        std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink = [remoteRenderer getSink];
        interface->setVideoOutput(sink);
        
        completion(remoteRenderer);
    });
}

@end

@interface OngoingCallThreadLocalContextWebrtc () {
    id<OngoingCallThreadLocalContextQueueWebrtc> _queue;
    int32_t _contextId;

    OngoingCallNetworkTypeWebrtc _networkType;
    NSTimeInterval _callReceiveTimeout;
    NSTimeInterval _callRingTimeout;
    NSTimeInterval _callConnectTimeout;
    NSTimeInterval _callPacketTimeout;
    
    TgVoip *_tgVoip;
    
    OngoingCallStateWebrtc _state;
    OngoingCallVideoStateWebrtc _videoState;
    bool _connectedOnce;
    OngoingCallRemoteVideoStateWebrtc _remoteVideoState;
    OngoingCallThreadLocalContextVideoCapturer *_videoCapturer;
    
    int32_t _signalBars;
    NSData *_lastDerivedState;
    
    void (^_sendSignalingData)(NSData *);
}

- (void)controllerStateChanged:(TgVoipState)state videoState:(OngoingCallVideoStateWebrtc)videoState;
- (void)signalBarsChanged:(int32_t)signalBars;

@end

@implementation VoipProxyServerWebrtc

- (instancetype _Nonnull)initWithHost:(NSString * _Nonnull)host port:(int32_t)port username:(NSString * _Nullable)username password:(NSString * _Nullable)password {
    self = [super init];
    if (self != nil) {
        _host = host;
        _port = port;
        _username = username;
        _password = password;
    }
    return self;
}

@end

@implementation VoipRtcServerWebrtc

- (instancetype _Nonnull)initWithHost:(NSString * _Nonnull)host port:(int32_t)port username:(NSString * _Nullable)username password:(NSString * _Nullable)password isTurn:(bool)isTurn {
    self = [super init];
    if (self != nil) {
        _host = host;
        _port = port;
        _username = username;
        _password = password;
        _isTurn = isTurn;
    }
    return self;
}

@end

static TgVoipNetworkType callControllerNetworkTypeForType(OngoingCallNetworkTypeWebrtc type) {
    switch (type) {
    case OngoingCallNetworkTypeWifi:
        return TgVoipNetworkType::WiFi;
    case OngoingCallNetworkTypeCellularGprs:
        return TgVoipNetworkType::Gprs;
    case OngoingCallNetworkTypeCellular3g:
        return TgVoipNetworkType::ThirdGeneration;
    case OngoingCallNetworkTypeCellularLte:
        return TgVoipNetworkType::Lte;
    default:
        return TgVoipNetworkType::ThirdGeneration;
    }
}

static TgVoipDataSaving callControllerDataSavingForType(OngoingCallDataSavingWebrtc type) {
    switch (type) {
    case OngoingCallDataSavingNever:
        return TgVoipDataSaving::Never;
    case OngoingCallDataSavingCellular:
        return TgVoipDataSaving::Mobile;
    case OngoingCallDataSavingAlways:
        return TgVoipDataSaving::Always;
    default:
        return TgVoipDataSaving::Never;
    }
}

@implementation OngoingCallThreadLocalContextWebrtc

static void (*InternalVoipLoggingFunction)(NSString *) = NULL;

+ (void)setupLoggingFunction:(void (*)(NSString *))loggingFunction {
    InternalVoipLoggingFunction = loggingFunction;
    TgVoip::setLoggingFunction([](std::string const &string) {
        if (InternalVoipLoggingFunction) {
            InternalVoipLoggingFunction([[NSString alloc] initWithUTF8String:string.c_str()]);
        }
    });
}

+ (void)applyServerConfig:(NSString *)string {
    if (string.length != 0) {
        TgVoip::setGlobalServerConfig(std::string(string.UTF8String));
    }
}

+ (int32_t)maxLayer {
    return 92;
}

+ (NSString *)version {
    return @"2.7.7";
}

- (instancetype _Nonnull)initWithQueue:(id<OngoingCallThreadLocalContextQueueWebrtc> _Nonnull)queue proxy:(VoipProxyServerWebrtc * _Nullable)proxy rtcServers:(NSArray<VoipRtcServerWebrtc *> * _Nonnull)rtcServers networkType:(OngoingCallNetworkTypeWebrtc)networkType dataSaving:(OngoingCallDataSavingWebrtc)dataSaving derivedState:(NSData * _Nonnull)derivedState key:(NSData * _Nonnull)key isOutgoing:(bool)isOutgoing primaryConnection:(OngoingCallConnectionDescriptionWebrtc * _Nonnull)primaryConnection alternativeConnections:(NSArray<OngoingCallConnectionDescriptionWebrtc *> * _Nonnull)alternativeConnections maxLayer:(int32_t)maxLayer allowP2P:(BOOL)allowP2P logPath:(NSString * _Nonnull)logPath sendSignalingData:(void (^)(NSData * _Nonnull))sendSignalingData videoCapturer:(OngoingCallThreadLocalContextVideoCapturer * _Nullable)videoCapturer {
    self = [super init];
    if (self != nil) {
        _queue = queue;
        assert([queue isCurrent]);
        
        _callReceiveTimeout = 20.0;
        _callRingTimeout = 90.0;
        _callConnectTimeout = 30.0;
        _callPacketTimeout = 10.0;
        _networkType = networkType;
        _sendSignalingData = [sendSignalingData copy];
        _videoCapturer = videoCapturer;
        if (videoCapturer != nil) {
            _videoState = OngoingCallVideoStateOutgoingRequested;
            _remoteVideoState = OngoingCallRemoteVideoStateActive;
        } else {
            _videoState = OngoingCallVideoStatePossible;
            _remoteVideoState = OngoingCallRemoteVideoStateInactive;
        }
        
        std::vector<uint8_t> derivedStateValue;
        derivedStateValue.resize(derivedState.length);
        [derivedState getBytes:derivedStateValue.data() length:derivedState.length];
        
        std::unique_ptr<TgVoipProxy> proxyValue = nullptr;
        if (proxy != nil) {
            TgVoipProxy *proxyObject = new TgVoipProxy();
            proxyObject->host = proxy.host.UTF8String;
            proxyObject->port = (uint16_t)proxy.port;
            proxyObject->login = proxy.username.UTF8String ?: "";
            proxyObject->password = proxy.password.UTF8String ?: "";
            proxyValue = std::unique_ptr<TgVoipProxy>(proxyObject);
        }
        
        std::vector<TgVoipRtcServer> parsedRtcServers;
        for (VoipRtcServerWebrtc *server in rtcServers) {
            parsedRtcServers.push_back((TgVoipRtcServer){
                .host = server.host.UTF8String,
                .port = (uint16_t)server.port,
                .login = server.username.UTF8String,
                .password = server.password.UTF8String,
                .isTurn = server.isTurn
            });
        }
        
        /*TgVoipCrypto crypto;
        crypto.sha1 = &TGCallSha1;
        crypto.sha256 = &TGCallSha256;
        crypto.rand_bytes = &TGCallRandomBytes;
        crypto.aes_ige_encrypt = &TGCallAesIgeEncrypt;
        crypto.aes_ige_decrypt = &TGCallAesIgeDecrypt;
        crypto.aes_ctr_encrypt = &TGCallAesCtrEncrypt;*/
        
        std::vector<TgVoipEndpoint> endpoints;
        NSArray<OngoingCallConnectionDescriptionWebrtc *> *connections = [@[primaryConnection] arrayByAddingObjectsFromArray:alternativeConnections];
        for (OngoingCallConnectionDescriptionWebrtc *connection in connections) {
            unsigned char peerTag[16];
            [connection.peerTag getBytes:peerTag length:16];
            
            TgVoipEndpoint endpoint;
            endpoint.endpointId = connection.connectionId;
            endpoint.host = {
                .ipv4 = std::string(connection.ip.UTF8String),
                .ipv6 = std::string(connection.ipv6.UTF8String)
            };
            endpoint.port = (uint16_t)connection.port;
            endpoint.type = TgVoipEndpointType::UdpRelay;
            memcpy(endpoint.peerTag, peerTag, 16);
            endpoints.push_back(endpoint);
        }
        
        TgVoipConfig config = {
            .initializationTimeout = _callConnectTimeout,
            .receiveTimeout = _callPacketTimeout,
            .dataSaving = callControllerDataSavingForType(dataSaving),
            .enableP2P = (bool)allowP2P,
            .enableAEC = false,
            .enableNS = true,
            .enableAGC = true,
            .enableCallUpgrade = false,
            .logPath = logPath.length == 0 ? "" : std::string(logPath.UTF8String),
            .maxApiLayer = [OngoingCallThreadLocalContextWebrtc maxLayer]
        };
        
        std::vector<uint8_t> encryptionKeyValue;
        encryptionKeyValue.resize(key.length);
        memcpy(encryptionKeyValue.data(), key.bytes, key.length);
        
        TgVoipEncryptionKey encryptionKey = {
            .value = encryptionKeyValue,
            .isOutgoing = isOutgoing,
        };
        
        __weak OngoingCallThreadLocalContextWebrtc *weakSelf = self;
        _tgVoip = TgVoip::makeInstance(
            config,
            { derivedStateValue },
            endpoints,
            proxyValue,
            parsedRtcServers,
            callControllerNetworkTypeForType(networkType),
            encryptionKey,
            [_videoCapturer getInterface],
            [weakSelf, queue](TgVoipState state, TgVoip::VideoState videoState) {
                [queue dispatch:^{
                    __strong OngoingCallThreadLocalContextWebrtc *strongSelf = weakSelf;
                    if (strongSelf) {
                        OngoingCallVideoStateWebrtc mappedVideoState;
                        switch (videoState) {
                            case TgVoip::VideoState::possible:
                                mappedVideoState = OngoingCallVideoStatePossible;
                                break;
                            case TgVoip::VideoState::outgoingRequested:
                                mappedVideoState = OngoingCallVideoStateOutgoingRequested;
                                break;
                            case TgVoip::VideoState::incomingRequested:
                                mappedVideoState = OngoingCallVideoStateIncomingRequested;
                                break;
                            case TgVoip::VideoState::active:
                                mappedVideoState = OngoingCallVideoStateActive;
                                break;
                        }
                        
                        [strongSelf controllerStateChanged:state videoState:mappedVideoState];
                    }
                }];
            },
            [weakSelf, queue](bool isActive) {
                [queue dispatch:^{
                    __strong OngoingCallThreadLocalContextWebrtc *strongSelf = weakSelf;
                    if (strongSelf) {
                        OngoingCallRemoteVideoStateWebrtc remoteVideoState;
                        if (isActive) {
                            remoteVideoState = OngoingCallRemoteVideoStateActive;
                        } else {
                            remoteVideoState = OngoingCallRemoteVideoStateInactive;
                        }
                        if (strongSelf->_remoteVideoState != remoteVideoState) {
                            strongSelf->_remoteVideoState = remoteVideoState;
                            if (strongSelf->_stateChanged) {
                                strongSelf->_stateChanged(strongSelf->_state, strongSelf->_videoState, strongSelf->_remoteVideoState);
                            }
                        }
                    }
                }];
            },
            [weakSelf, queue](const std::vector<uint8_t> &data) {
            NSData *mappedData = [[NSData alloc] initWithBytes:data.data() length:data.size()];
                [queue dispatch:^{
                    __strong OngoingCallThreadLocalContextWebrtc *strongSelf = weakSelf;
                    if (strongSelf) {
                        [strongSelf signalingDataEmitted:mappedData];
                    }
                }];
            }
        );
        
        _state = OngoingCallStateInitializing;
        _signalBars = -1;
    }
    return self;
}

- (void)dealloc {
    assert([_queue isCurrent]);
    if (_tgVoip != NULL) {
        [self stop:nil];
    }
}

- (bool)needRate {
    return false;
}

- (void)stop:(void (^)(NSString *, int64_t, int64_t, int64_t, int64_t))completion {
    if (_tgVoip) {
        TgVoipFinalState finalState = _tgVoip->stop();
        
        NSString *debugLog = [NSString stringWithUTF8String:finalState.debugLog.c_str()];
        _lastDerivedState = [[NSData alloc] initWithBytes:finalState.persistentState.value.data() length:finalState.persistentState.value.size()];
        
        delete _tgVoip;
        _tgVoip = NULL;
        
        if (completion) {
            completion(debugLog, finalState.trafficStats.bytesSentWifi, finalState.trafficStats.bytesReceivedWifi, finalState.trafficStats.bytesSentMobile, finalState.trafficStats.bytesReceivedMobile);
        }
    }
}

- (NSString *)debugInfo {
    if (_tgVoip != nil) {
        NSString *version = [self version];
        return [NSString stringWithFormat:@"WebRTC, Version: %@", version];
        //auto rawDebugString = _tgVoip->getDebugInfo();
        //return [NSString stringWithUTF8String:rawDebugString.c_str()];
    } else {
        return nil;
    }
}

- (NSString *)version {
    if (_tgVoip != nil) {
        return @"2.7.7";//[NSString stringWithUTF8String:_tgVoip->getVersion().c_str()];
    } else {
        return nil;
    }
}

- (NSData * _Nonnull)getDerivedState {
    if (_tgVoip) {
        auto persistentState = _tgVoip->getPersistentState();
        return [[NSData alloc] initWithBytes:persistentState.value.data() length:persistentState.value.size()];
    } else if (_lastDerivedState != nil) {
        return _lastDerivedState;
    } else {
        return [NSData data];
    }
}

- (void)controllerStateChanged:(TgVoipState)state videoState:(OngoingCallVideoStateWebrtc)videoState {
    OngoingCallStateWebrtc callState = OngoingCallStateInitializing;
    switch (state) {
        case TgVoipState::Estabilished:
            callState = OngoingCallStateConnected;
            break;
        case TgVoipState::Failed:
            callState = OngoingCallStateFailed;
            break;
        case TgVoipState::Reconnecting:
            callState = OngoingCallStateReconnecting;
            break;
        default:
            break;
    }
    
    if (_state != callState || _videoState != videoState) {
        _state = callState;
        _videoState = videoState;
        
        if (_stateChanged) {
            _stateChanged(_state, _videoState, _remoteVideoState);
        }
    }
}

- (void)signalBarsChanged:(int32_t)signalBars {
    if (signalBars != _signalBars) {
        _signalBars = signalBars;
        
        if (_signalBarsChanged) {
            _signalBarsChanged(signalBars);
        }
    }
}

- (void)signalingDataEmitted:(NSData *)data {
    if (_sendSignalingData) {
        _sendSignalingData(data);
    }
}

- (void)addSignalingData:(NSData *)data {
    if (_tgVoip) {
        std::vector<uint8_t> mappedData;
        mappedData.resize(data.length);
        [data getBytes:mappedData.data() length:data.length];
        _tgVoip->receiveSignalingData(mappedData);
    }
}

- (void)setIsMuted:(bool)isMuted {
    if (_tgVoip) {
        _tgVoip->setMuteMicrophone(isMuted);
    }
}

- (void)setNetworkType:(OngoingCallNetworkTypeWebrtc)networkType {
    if (_networkType != networkType) {
        _networkType = networkType;
        if (_tgVoip) {
            _tgVoip->setNetworkType(callControllerNetworkTypeForType(networkType));
        }
    }
}

- (void)makeIncomingVideoView:(void (^_Nonnull)(OngoingCallThreadLocalContextWebrtcVideoView * _Nullable))completion {
    if (_tgVoip) {
        __weak OngoingCallThreadLocalContextWebrtc *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            VideoMetalView *remoteRenderer = [[VideoMetalView alloc] initWithFrame:CGRectZero];
            remoteRenderer.videoContentMode = UIViewContentModeScaleAspectFill;
            
            std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink = [remoteRenderer getSink];
            __strong OngoingCallThreadLocalContextWebrtc *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_tgVoip->setIncomingVideoOutput(sink);
            }
            
            completion(remoteRenderer);
        });
    }
}

- (void)requestVideo:(OngoingCallThreadLocalContextVideoCapturer * _Nullable)videoCapturer {
    if (_tgVoip && _videoCapturer == nil) {
        _videoCapturer = videoCapturer;
        _tgVoip->requestVideo([_videoCapturer getInterface]);
    }
}

@end

@implementation OngoingCallThreadLocalContextWebrtcVideoView : UIView

- (void)setOnFirstFrameReceived:(void (^ _Nullable)())onFirstFrameReceived {
}

@end
