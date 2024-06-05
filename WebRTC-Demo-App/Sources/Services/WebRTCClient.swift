//
//  WebRTCClient.swift
//  WebRTC
//
//  Created by Stasel on 20/05/2018.
//  Copyright © 2018 Stasel. All rights reserved.
//

import Foundation
import WebRTC
import WebKit

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data)
}

final class WebRTCClient: NSObject {
    
    // The `RTCPeerConnectionFactory` is in charge of creating new RTCPeerConnection instances.
    // A new RTCPeerConnection should be created every new call, but the factory is shared.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        //videoEncoderFactory.preferredCodec = RTCVideoCodecInfo(name: "H264")
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    
    weak var delegate: WebRTCClientDelegate?
    private let peerConnection: RTCPeerConnection
    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    //private let audioQueue = DispatchQueue(label: "audio")
    private var mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]    
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localDataChannel: RTCDataChannel?
    private var remoteDataChannel: RTCDataChannel?
    
    private var videoStarted = false;
    public var webView: WKWebView?

    @available(*, unavailable)
    override init() {
        fatalError("WebRTCClient:init is unavailable")
    }
    
    required init(iceServers: [String]) {
        let config = RTCConfiguration()
        
        config.iceServers = [RTCIceServer(urlStrings: Config.default.webRTCIceServers)]
        
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        config.continualGatheringPolicy = .gatherContinually
        
        config.allowCodecSwitching = false;
        
        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":kRTCMediaConstraintsValueTrue])
        
        guard let peerConnection = WebRTCClient.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError("Could not create new RTCPeerConnection")
        }
        
        self.peerConnection = peerConnection
        
        super.init()
        self.createMediaSenders()
       // self.configureAudioSession()
        self.peerConnection.delegate = self
    }
    
    // MARK: Signaling
    func offer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
            
        // TODO - this should be somewhere more sensible.
        let videoTransceiver = self.peerConnection.transceivers.first { $0.mediaType == .video }
        let videoSender = videoTransceiver?.sender
        
        
        let encodingParameters = RTCRtpEncodingParameters()
        let maxBitrateBps : NSNumber = 16000000 //16mbps
        let minBitrateBps : NSNumber = 8000000 //8mbps
        encodingParameters.maxBitrateBps = maxBitrateBps
        encodingParameters.minBitrateBps = maxBitrateBps
        encodingParameters.scaleResolutionDownBy = nil
        encodingParameters.adaptiveAudioPacketTime = false
        encodingParameters.maxFramerate = 60
        encodingParameters.bitratePriority = 1
        
        
        let parameters = videoSender?.parameters
        
        if let existingEncodings = parameters?.encodings, existingEncodings.count > 0 {
            existingEncodings[0].maxBitrateBps = maxBitrateBps
            existingEncodings[0].minBitrateBps = minBitrateBps
            existingEncodings[0].scaleResolutionDownBy = nil
            existingEncodings[0].adaptiveAudioPacketTime = false
            existingEncodings[0].maxFramerate = 60
            encodingParameters.bitratePriority = 1
            
            parameters?.encodings = existingEncodings
        } else {
            parameters?.encodings = [encodingParameters]
        }
        
        videoSender?.parameters = parameters ?? RTCRtpParameters()

        self.mediaConstrains["minWidth"] = "1920"
        //self.mediaConstrains["maxWidth"] = "641"
        self.mediaConstrains["minHeight"] = "1080"
        self.mediaConstrains["height"] = "1080"
        self.mediaConstrains["width"] = "1920"
        self.mediaConstrains["minFrameRate"] = "30"
        self.mediaConstrains["maxFrameRate"] = "60"
        self.mediaConstrains["scaleResolutionDownBy"] = "1" //default, wont scale
        
        
        //let minWdith new RTCPair(initWithKey:"minWidth" value:"640")
        
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: self.mediaConstrains)
        
        // should go nowhere with no connection?
        self.peerConnection.offer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }
            
            
            
            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                completion(sdp)
            })
            
            
            // Convert the offer to a JSON string
            let sdpTypeString = RTCSessionDescription.string(for: sdp.type)
            let offerDict: [String: Any] = ["type": sdpTypeString, "sdp": sdp.sdp]
            let jsonData = try? JSONSerialization.data(withJSONObject: offerDict, options: [])
            let jsonString = String(data: jsonData!, encoding: .utf8)
            
            // Send the SDP offer to the JavaScript side on the main thread
            DispatchQueue.main.async {
                self.webView!.evaluateJavaScript("receiveOfferFromiOS(\(jsonString!))", completionHandler: nil)
            }
            
            
        }
    }
    
    func receiveAnswerJson(answerString: String){
        
            // Parse the answer JSON string into an RTCSessionDescription object
            if let data = answerString.data(using: .utf8),
               let answerDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let sdpTypeString = answerDict["type"] as? String,
               let sdp = answerDict["sdp"] as? String {
                
                let sdpType = RTCSessionDescription.type(for: sdpTypeString)
                let answer = RTCSessionDescription(type: sdpType, sdp: sdp)
                                
                // Set the received answer as the remote description
                DispatchQueue.main.async {
                    self.peerConnection.setRemoteDescription(answer) { (error) in
                        if let error = error {
                            print("Failed to set remote description: \(error.localizedDescription)")
                        } else {
                            print("Remote description set successfully")
                        }
                    }
                }
            }
    }
    
    func receiveOfferJson(answerString: String){
        
        // Parse the answer JSON string into an RTCSessionDescription object
        if let data = answerString.data(using: .utf8),
           let answerDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let sdpTypeString = answerDict["type"] as? String,
           let sdp = answerDict["sdp"] as? String {
            
            let sdpType = RTCSessionDescription.type(for: sdpTypeString)
            let offer = RTCSessionDescription(type: sdpType, sdp: sdp)
            
            // Set the received offer as the remote description
            DispatchQueue.main.async {
                self.peerConnection.setRemoteDescription(offer) { (error) in
                    if let error = error {
                        print("Failed to set remote description: \(error.localizedDescription)")
                    } else {
                        print("Remote offer description set successfully")
                        self.answer {offer in
                            print("answer sent")
                        }
                    }
                }
            }
        }
    }
    
    func answer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void)  {
        
        // TODO - this should be somewhere more sensible.
        let videoTransceiver = self.peerConnection.transceivers.first { $0.mediaType == .video }
        let videoSender = videoTransceiver?.sender
        
        
        let encodingParameters = RTCRtpEncodingParameters()
        let maxBitrateBps : NSNumber = 16000000 //16mbps
        let minBitrateBps : NSNumber = 8000000 //8mbps
        encodingParameters.maxBitrateBps = maxBitrateBps
        encodingParameters.minBitrateBps = maxBitrateBps
        encodingParameters.scaleResolutionDownBy = nil
        encodingParameters.adaptiveAudioPacketTime = false
        encodingParameters.maxFramerate = 60
        encodingParameters.bitratePriority = 1
        
        
        let parameters = videoSender?.parameters
        
        if let existingEncodings = parameters?.encodings, existingEncodings.count > 0 {
            existingEncodings[0].maxBitrateBps = maxBitrateBps
            existingEncodings[0].minBitrateBps = minBitrateBps
            existingEncodings[0].scaleResolutionDownBy = nil
            existingEncodings[0].adaptiveAudioPacketTime = false
            existingEncodings[0].maxFramerate = 60
            encodingParameters.bitratePriority = 1
            
            parameters?.encodings = existingEncodings
        } else {
            parameters?.encodings = [encodingParameters]
        }
        
        videoSender?.parameters = parameters ?? RTCRtpParameters()
        
        self.mediaConstrains["minWidth"] = "1920"
        //self.mediaConstrains["maxWidth"] = "641"
        self.mediaConstrains["minHeight"] = "1080"
        self.mediaConstrains["height"] = "1080"
        self.mediaConstrains["width"] = "1920"
        self.mediaConstrains["minFrameRate"] = "30"
        self.mediaConstrains["maxFrameRate"] = "60"
        self.mediaConstrains["scaleResolutionDownBy"] = "1" //default, wont scale
        
        
        //let minWdith new RTCPair(initWithKey:"minWidth" value:"640")
        
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: self.mediaConstrains)
        self.peerConnection.answer(for: constrains) { (sdp, error) in
            //print(sdp?.description)
            guard let sdp = sdp else {
                return
            }
            
            
            // Convert the offer to a JSON string
            let sdpTypeString = RTCSessionDescription.string(for: sdp.type)
            let offerDict: [String: Any] = ["type": sdpTypeString, "sdp": sdp.sdp]
            let jsonData = try? JSONSerialization.data(withJSONObject: offerDict, options: [])
            let jsonString = String(data: jsonData!, encoding: .utf8)
            
            // Send the SDP offer to the JavaScript side on the main thread
            DispatchQueue.main.async {
                self.webView!.evaluateJavaScript("receiveAnswerFromiOS(\(jsonString!))", completionHandler: nil)
            }
            
            
            print("Local answer descriptino set")
            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                completion(sdp)
            })
        }
    }
    
    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> ()) {
        self.peerConnection.setRemoteDescription(remoteSdp, completionHandler: completion)
    }
    
    func set(remoteCandidate: RTCIceCandidate, completion: @escaping (Error?) -> ()) {
        self.peerConnection.add(remoteCandidate, completionHandler: completion)
    }
    
    // MARK: Media
    func startCaptureLocalVideo(renderer: RTCVideoRenderer) {
        
        guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else {
            return
        }
        
        guard let backCamera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == .back }) else {
            return
        }
        
        let supportedFormats = RTCCameraVideoCapturer.supportedFormats(for: backCamera)
        
        let targetWidth: Int32 = 1920
        let targetHeight: Int32 = 1080
        let targetFps: Float64 = 60
        let targetPixelFormatString = "420f"
        /*let targetPixelFormatType = FourCharCode(targetPixelFormatString.utf8.reduce(0, { sum, character in
         return sum << 8 | UInt32(character)
         }))*/
        
        /*
        for format in supportedFormats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixelFormatType = format.formatDescription.mediaSubType.rawValue
            let pixelFormatString = FourCharCode(pixelFormatType).toString()
            
            print("Resolution: \(dimensions.width) x \(dimensions.height), Pixel Format: \(pixelFormatString)")
            
            for frameRateRange in format.videoSupportedFrameRateRanges {
                print("Frame Rate Range: \(frameRateRange.minFrameRate) - \(frameRateRange.maxFrameRate) fps")
            }
            
            print("---")
             
        }
         */
        
        let matchingFormats = supportedFormats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixelFormatType = format.formatDescription.mediaSubType.rawValue
            let pixelFormatString = FourCharCode(pixelFormatType).toString()
            //let frameRateRanges = format.videoSupportedFrameRateRanges
            /*
            for frameRateRange in frameRateRanges {
                print("- \(frameRateRange.minFrameRate) - \(frameRateRange.maxFrameRate) fps")
            }
             */
            
            let desiredResolution = "\(targetWidth)x\(targetHeight)"
            let actualResolution = "\(dimensions.width)x\(dimensions.height)"
            let desiredPixelFormat = targetPixelFormatString
            let actualPixelFormat = pixelFormatString
           /*
            let desiredFrameRate = targetFps
            let actualFrameRate = frameRateRanges.filter { $0.minFrameRate <= targetFps && $0.maxFrameRate >= targetFps }.first?.maxFrameRate ?? 0
            */
            print("  Desired resolution: \(desiredResolution), actual resolution: \(actualResolution)")
            print("  Desired pixel format: \(desiredPixelFormat), actual pixel format: \(actualPixelFormat)")
            //print("  Desired frame rate: \(desiredFrameRate) fps, actual frame rate: \(actualFrameRate) fps")
            
            return dimensions.width == targetWidth && dimensions.height == targetHeight
            && pixelFormatString == targetPixelFormatString
            //&& frameRateRanges.contains(where: { $0.minFrameRate <= targetFps && $0.maxFrameRate >= targetFps })
        }
        

        
        guard let format = matchingFormats.first else {
            print("No matching format found")
            return
        }
        
        let pixelFormatType = format.formatDescription.mediaSubType.rawValue
        let pixelFormatString = FourCharCode(pixelFormatType).toString()
        let frameRateRanges = format.videoSupportedFrameRateRanges
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("   actual resolution: \(dimensions.width)x\(dimensions.height)")
        print("  actual pixel format: \(pixelFormatString)")
        print("  actual frame rate: \(frameRateRanges) fps")
        
        
        capturer.startCapture(with: backCamera, format: format, fps: Int(targetFps))
       /*
        let localRenderer = RTCMTLVideoView(frame: self.localVideoView?.frame ?? CGRect.zero)
        localRenderer.videoContentMode = .scaleAspectFill
        
        self.localVideoTrack?.add(renderer)
        */
    }



    
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        self.remoteVideoTrack?.add(renderer)
    }
    
    private func configureAudioSession() {
        self.rtcAudioSession.lockForConfiguration()
        do {
            try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue)
            try self.rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
        } catch let error {
            debugPrint("Error changeing AVAudioSession category: \(error)")
        }
        self.rtcAudioSession.unlockForConfiguration()
    }
    
    private func createMediaSenders() {
        let streamId = "stream"
        
        // Audio
        //let audioTrack = self.createAudioTrack()
        //self.peerConnection.add(audioTrack, streamIds: [streamId])
        
        // Video
        let videoTrack = self.createVideoTrack()
        self.localVideoTrack = videoTrack
        

            
        self.peerConnection.add(videoTrack, streamIds: [streamId])
        self.remoteVideoTrack = self.peerConnection.transceivers.first { $0.mediaType == .video }?.receiver.track as? RTCVideoTrack
        
        // Data
        if let dataChannel = createDataChannel() {
            dataChannel.delegate = self
            self.localDataChannel = dataChannel
        }
    }
    
    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = WebRTCClient.factory.audioSource(with: audioConstrains)
        let audioTrack = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "audio0")
        return audioTrack
    }
    
    private func createVideoTrack() -> RTCVideoTrack {
        let videoSource = WebRTCClient.factory.videoSource()
        
        #if targetEnvironment(simulator)
        self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        #else
        self.videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        #endif
        
        
        let videoTrack = WebRTCClient.factory.videoTrack(with: videoSource, trackId: "video0")
        
        return videoTrack
    }
    
    // MARK: Data Channels
    private func createDataChannel() -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        guard let dataChannel = self.peerConnection.dataChannel(forLabel: "WebRTCData", configuration: config) else {
            debugPrint("Warning: Couldn't create data channel.")
            return nil
        }
        return dataChannel
    }
    
    func sendData(_ data: Data) {
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        self.remoteDataChannel?.sendData(buffer)
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        debugPrint("peerConnection new signaling state: \(stateChanged)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        debugPrint("peerConnection did add stream")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        debugPrint("peerConnection did remove stream")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        debugPrint("peerConnection should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        debugPrint("peerConnection new connection state: \(newState)")
        self.delegate?.webRTCClient(self, didChangeConnectionState: newState)
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        debugPrint("peerConnection new gathering state: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        self.delegate?.webRTCClient(self, didDiscoverLocalCandidate: candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        debugPrint("peerConnection did remove candidate(s)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        debugPrint("peerConnection did open data channel")
        self.remoteDataChannel = dataChannel
    }
}
extension WebRTCClient {
    private func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool) {
        peerConnection.transceivers
            .compactMap { return $0.sender.track as? T }
            .forEach { $0.isEnabled = isEnabled }
    }
}

extension FourCharCode {
    func toString() -> String {
        let n = Int(self)
        var s: String = ""
        s.append(Character(UnicodeScalar((n >> 24) & 255)!))
        s.append(Character(UnicodeScalar((n >> 16) & 255)!))
        s.append(Character(UnicodeScalar((n >> 8) & 255)!))
        s.append(Character(UnicodeScalar(n & 255)!))
        return s
    }
    init?(fromString string: String) {
        guard string.count == 4 else { return nil }
        var code: FourCharCode = 0
        for char in string.utf16 {
            code = (code << 8) | FourCharCode(char)
        }
        self.init(code)
    }
}


// MARK: - Video control
extension WebRTCClient {
    func hideVideo() {
        self.setVideoEnabled(false)
    }
    func showVideo() {
        self.setVideoEnabled(true)
    }
    private func setVideoEnabled(_ isEnabled: Bool) {
        setTrackEnabled(RTCVideoTrack.self, isEnabled: isEnabled)
    }
}
// MARK:- Audio control
extension WebRTCClient {
    func muteAudio() {
        self.setAudioEnabled(false)
    }
    
    func unmuteAudio() {
        self.setAudioEnabled(true)
    }
    
    
    
    private func setAudioEnabled(_ isEnabled: Bool) {
        setTrackEnabled(RTCAudioTrack.self, isEnabled: isEnabled)
    }
}

extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        debugPrint("dataChannel did change state: \(dataChannel.readyState)")
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        self.delegate?.webRTCClient(self, didReceiveData: buffer.data)
    }
}
