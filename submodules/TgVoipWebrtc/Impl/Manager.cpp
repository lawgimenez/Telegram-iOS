#include "Manager.h"

#include "rtc_base/byte_buffer.h"

#ifdef TGVOIP_NAMESPACE
namespace TGVOIP_NAMESPACE {
#endif

static rtc::Thread *makeNetworkThread() {
    static std::unique_ptr<rtc::Thread> value = rtc::Thread::CreateWithSocketServer();
    value->SetName("WebRTC-Network", nullptr);
    value->Start();
    return value.get();
}


static rtc::Thread *getNetworkThread() {
    static rtc::Thread *value = makeNetworkThread();
    return value;
}

static rtc::Thread *makeMediaThread() {
    static std::unique_ptr<rtc::Thread> value = rtc::Thread::Create();
    value->SetName("WebRTC-Media", nullptr);
    value->Start();
    return value.get();
}

rtc::Thread *Manager::getMediaThread() {
    static rtc::Thread *value = makeMediaThread();
    return value;
}

Manager::Manager(
    rtc::Thread *thread,
    TgVoipEncryptionKey encryptionKey,
    bool enableP2P,
    std::vector<TgVoipRtcServer> const &rtcServers,
    std::shared_ptr<TgVoipVideoCaptureInterface> videoCapture,
    std::function<void (const TgVoipState &, VideoState)> stateUpdated,
    std::function<void (bool)> remoteVideoIsActiveUpdated,
    std::function<void (const std::vector<uint8_t> &)> signalingDataEmitted
) :
_thread(thread),
_encryptionKey(encryptionKey),
_enableP2P(enableP2P),
_rtcServers(rtcServers),
_videoCapture(videoCapture),
_stateUpdated(stateUpdated),
_remoteVideoIsActiveUpdated(remoteVideoIsActiveUpdated),
_signalingDataEmitted(signalingDataEmitted),
_state(TgVoipState::Reconnecting),
_videoState(VideoState::possible) {
    assert(_thread->IsCurrent());
    if (videoCapture != nullptr) {
        _videoState = VideoState::outgoingRequested;
    }
}

Manager::~Manager() {
    assert(_thread->IsCurrent());
}

void Manager::start() {
    if (_videoCapture != nullptr) {
        _videoState = VideoState::active;
    }
    auto weakThis = std::weak_ptr<Manager>(shared_from_this());
    _networkManager.reset(new ThreadLocalObject<NetworkManager>(getNetworkThread(), [encryptionKey = _encryptionKey, enableP2P = _enableP2P, rtcServers = _rtcServers, thread = _thread, weakThis, signalingDataEmitted = _signalingDataEmitted]() {
        return new NetworkManager(
            getNetworkThread(),
            encryptionKey,
            enableP2P,
            rtcServers,
            [thread, weakThis](const NetworkManager::State &state) {
                thread->PostTask(RTC_FROM_HERE, [weakThis, state]() {
                    auto strongThis = weakThis.lock();
                    if (strongThis == nullptr) {
                        return;
                    }
                    TgVoipState mappedState;
                    if (state.isReadyToSendData) {
                        mappedState = TgVoipState::Estabilished;
                        if (!strongThis->_didConnectOnce) {
                            strongThis->_didConnectOnce = true;
                            if (strongThis->_videoState == VideoState::outgoingRequested) {
                                strongThis->_videoState = VideoState::active;
                            }
                        }
                    } else {
                        mappedState = TgVoipState::Reconnecting;
                    }
                    strongThis->_state = mappedState;
                    strongThis->_stateUpdated(mappedState, strongThis->_videoState);
                    
                    strongThis->_mediaManager->perform([state](MediaManager *mediaManager) {
                        mediaManager->setIsConnected(state.isReadyToSendData);
                    });
                });
            },
            [thread, weakThis](const rtc::CopyOnWriteBuffer &packet) {
                thread->PostTask(RTC_FROM_HERE, [weakThis, packet]() {
                    auto strongThis = weakThis.lock();
                    if (strongThis == nullptr) {
                        return;
                    }
                    strongThis->_mediaManager->perform([packet](MediaManager *mediaManager) {
                        mediaManager->receivePacket(packet);
                    });
                });
            },
            [signalingDataEmitted](const std::vector<uint8_t> &data) {
                rtc::CopyOnWriteBuffer buffer;
                uint8_t mode = 3;
                buffer.AppendData(&mode, 1);
                buffer.AppendData(data.data(), data.size());
                std::vector<uint8_t> augmentedData;
                augmentedData.resize(buffer.size());
                memcpy(augmentedData.data(), buffer.data(), buffer.size());
                signalingDataEmitted(augmentedData);
            }
        );
    }));
    bool isOutgoing = _encryptionKey.isOutgoing;
    _mediaManager.reset(new ThreadLocalObject<MediaManager>(getMediaThread(), [isOutgoing, thread = _thread, videoCapture = _videoCapture, weakThis]() {
        return new MediaManager(
            getMediaThread(),
            isOutgoing,
            videoCapture,
            [thread, weakThis](const rtc::CopyOnWriteBuffer &packet) {
                thread->PostTask(RTC_FROM_HERE, [weakThis, packet]() {
                    auto strongThis = weakThis.lock();
                    if (strongThis == nullptr) {
                        return;
                    }
                    strongThis->_networkManager->perform([packet](NetworkManager *networkManager) {
                        networkManager->sendPacket(packet);
                    });
                });
            },
            [thread, weakThis](bool isActive) {
                thread->PostTask(RTC_FROM_HERE, [weakThis, isActive]() {
                    auto strongThis = weakThis.lock();
                    if (strongThis == nullptr) {
                        return;
                    }
                    strongThis->notifyIsLocalVideoActive(isActive);
                });
            }
        );
    }));
}

void Manager::receiveSignalingData(const std::vector<uint8_t> &data) {
    rtc::CopyOnWriteBuffer buffer;
    buffer.AppendData(data.data(), data.size());
    
    if (buffer.size() < 1) {
        return;
    }
    
    rtc::ByteBufferReader reader((const char *)buffer.data(), buffer.size());
    uint8_t mode = 0;
    if (!reader.ReadUInt8(&mode)) {
        return;
    }
    
    if (mode == 1) {
        if (_videoState == VideoState::possible) {
            _videoState = VideoState::incomingRequested;
            _stateUpdated(_state, _videoState);
        }
    } else if (mode == 2) {
    } else if (mode == 3) {
        auto candidatesData = buffer.Slice(1, buffer.size() - 1);
        _networkManager->perform([candidatesData](NetworkManager *networkManager) {
            networkManager->receiveSignalingData(candidatesData);
        });
    } else if (mode == 4) {
        uint8_t value = 0;
        if (reader.ReadUInt8(&value)) {
            _remoteVideoIsActiveUpdated(value != 0);
        }
    }
}

void Manager::requestVideo(std::shared_ptr<TgVoipVideoCaptureInterface> videoCapture) {
    if (videoCapture != nullptr) {
        if (_videoState == VideoState::possible) {
            _videoState = VideoState::outgoingRequested;
            
            rtc::CopyOnWriteBuffer buffer;
            uint8_t mode = 1;
            buffer.AppendData(&mode, 1);
            
            std::vector<uint8_t> data;
            data.resize(buffer.size());
            memcpy(data.data(), buffer.data(), buffer.size());
            
            _signalingDataEmitted(data);
            
            /*_mediaManager->perform([](MediaManager *mediaManager) {
                mediaManager->setSendVideo(true);
            });*/
            
            _stateUpdated(_state, _videoState);
        }
    }
}

void Manager::setMuteOutgoingAudio(bool mute) {
    _mediaManager->perform([mute](MediaManager *mediaManager) {
        mediaManager->setMuteOutgoingAudio(mute);
    });
}

void Manager::notifyIsLocalVideoActive(bool isActive) {
    rtc::CopyOnWriteBuffer buffer;
    uint8_t mode = 4;
    buffer.AppendData(&mode, 1);
    uint8_t value = isActive ? 1 : 0;
    buffer.AppendData(&value, 1);
    
    std::vector<uint8_t> data;
    data.resize(buffer.size());
    memcpy(data.data(), buffer.data(), buffer.size());
    _signalingDataEmitted(data);
}

void Manager::setIncomingVideoOutput(std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink) {
    _mediaManager->perform([sink](MediaManager *mediaManager) {
        mediaManager->setIncomingVideoOutput(sink);
    });
}

#ifdef TGVOIP_NAMESPACE
}
#endif
