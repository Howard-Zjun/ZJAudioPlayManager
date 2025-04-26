//
//  ZJAudioPlayManager.swift
//  ListenSpeak
//
//  Created by ios on 2025/2/24.
//

import UIKit
import AVFoundation
import Alamofire

let CACHE_BASE_PATH = NSHomeDirectory() + "/Library/Caches"

/*
 特性：
 1.播放新语音能中断上一个正在播放的
 2.识别到是网络链接能进行下载
 3.适合连续播放
 */
class ZJAudioPlayManager: NSObject {
    
    enum EndType {
        case normal // 正常
        case interrupt // 中断
        case playOther // 播放别的音频
        case notAudio // 不是音频
        case error // 错误
    }
    
    static let shared = ZJAudioPlayManager()
    
    var player: AVAudioPlayer?
    
    /// 正常播放前
    var beforePlayBlock: (() -> Void)?
    
    /// 正常播放后
    var afterPlayBlock: ((EndType) -> Void)?
    
    var progressBlock: ((TimeInterval) -> Void)?
    
    var audioURL: URL?
    
    var isPlayEnd = false
    
    var folderPath: String {
        CACHE_BASE_PATH + "/" + "mp3cache"
    }
    
    var currentTimer: Timer?
    
    deinit {
        currentTimer?.invalidate()
        currentTimer = nil
        NotificationCenter.default.removeObserver(self)
    }
    
    override init() {
        super.init()
        
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            
            guard isForeground, !isPlayEnd else { return }
            
            switch type {
            case .began:
                pauseHandle()
                afterPlayBlock?(.interrupt)
            case .ended:
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[\(#file):\(#line)] \(#function) 音频播放中断结束，可恢复播放")
                    playHandle()
                } else {
                    print("[\(#file):\(#line)] \(#function) 音频播放中断结束，但不建议恢复播放")
                }
            default: ()
            }
        }
        
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] info in
            guard let self = self else { return }
            guard !isPlayEnd else {
                print("[\(#file):\(#line)] \(#function) 音频已经播放完毕，无须继续播放")
                return
            }

            print("[\(#file):\(#line)] \(#function) 进入前台")
            playHandle()
        }
    }
    
}

extension ZJAudioPlayManager {

    var isPlaying: Bool {
        return player?.isPlaying ?? false
    }
}

// MARK: - 播放/暂停/注销入口
extension ZJAudioPlayManager {
    
    func playAudio(resourceName: String, mineType: String, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: mineType) else {
            print("[\(#file):\(#line)] \(#function) 本地音频资源不存在")
            afterPlayBlock?(.notAudio)
            return
        }
        
        playAudio(url: url, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
    }
    
    func playAudio(urlStr: String, preDownload: Bool = false, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        if urlStr.hasPrefix("http") {
            if let url = URL(string: urlStr) {
                playAudio(url: url, preDownload: preDownload, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
            } else {
                afterPlayBlock?(.notAudio)
            }
        } else {
            if FileManager.default.fileExists(atPath: urlStr) {
                let url = URL(fileURLWithPath: urlStr)
                playAudio(url: url, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
            } else {
                afterPlayBlock?(.notAudio)
            }
        }
    }
    
    func pauseAudio() {
        pauseHandle()
    }
    
    func stopAudio() {
        stopHandle()
    }
    
    func playAudio(url: URL, preDownload: Bool, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        if preDownload {
            downloadAudio(url: url, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
        } else {
            playAudio(url: url, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
        }
    }
    
    func playAudio(url: URL, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        // 处理正在播放的情况
        if let player, player.isPlaying, !isPlayEnd {
            currentTimer?.invalidate()
            currentTimer = nil
            player.stop()
            self.afterPlayBlock?(.playOther)
        }
        
        self.audioURL = url
        self.beforePlayBlock = beforePlayBlock
        self.afterPlayBlock = afterPlayBlock
        self.progressBlock = progressBlock
     
        if !url.absoluteString.hasPrefix("http") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                playAudio(player: player)
            } catch {
                print("[\(#file):\(#line)] \(#function) error: \(error)")
                afterPlayBlock?(.error)
                return
            }
        } else {
            DispatchQueue.global(qos: .background).async {
                do {
                    let data = try Data(contentsOf: url)
                    let player = try AVAudioPlayer(data: data)
                    DispatchQueue.main.async {
                        self.playAudio(player: player)
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("[\(#file):\(#line) \(#function) error: \(error)")
                        afterPlayBlock?(.error)
                        return
                    }
                }
            }
        }
    }
    
    private func playAudio(player: AVAudioPlayer) {
        self.player = player
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[\(#file):\(#line)] \(#function) error: \(error)")
            afterPlayBlock?(.error)
            return
        }
        
        player.volume = 1
        player.delegate = self
        player.enableRate = true
        
        isPlayEnd = false
        beforePlayBlock?()
        player.prepareToPlay()
        
        playHandle()
    }
    
    private func downloadAudio(url: URL, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        print("[\(#file):\(#line) \(#function) 下载")
        
        guard url.absoluteString.hasPrefix("http") else {
            print("[\(#file):\(#line)] \(#function) 不是网络链接")
            playAudio(url: url, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
            return
        }
        let savePath = filePath(url: url)
        let locationURL = URL(fileURLWithPath: savePath)
        
        if FileManager.default.fileExists(atPath: savePath) {
            print("[\(#file):\(#function)]-\(#line) 文件已存在")
            playAudio(url: locationURL, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
        } else {
            let request = AF.download(url.absoluteString, to: { temporaryURL, response in
                return (locationURL, [.removePreviousFile, .createIntermediateDirectories])
            })
            request.response { [weak self] response in
                print("[\(#file):\(#line)] \(#function) 下载完成")
                self?.playAudio(url: locationURL, beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
            }
            request.resume()
        }
    }
}

extension ZJAudioPlayManager {

    private func playHandle() {
        currentTimer?.invalidate()
        currentTimer = nil
        
        guard let player else { return }
        
        player.play()
        
        currentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { [weak self] timer in
            guard let self = self else { return }
            
            progressBlock?(player.currentTime)
        })
    }
    
    // 暂停，还能继续播放
    private func pauseHandle() {
        currentTimer?.invalidate()
        currentTimer = nil
        player?.pause()
    }
    
    // 停止，不能继续播放
    private func stopHandle() {
        currentTimer?.invalidate()
        currentTimer = nil
        player?.stop()
        player = nil
        isPlayEnd = true
    }
    
    private func filePath(url: URL) -> String {
        folderPath + "/" + RBEncrypt.md5_16(url.absoluteString) + "." + url.pathExtension
    }
}

// MARK: - AVAudioPlayerDelegate
extension ZJAudioPlayManager: AVAudioPlayerDelegate {
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlayEnd = true
        currentTimer?.invalidate()
        currentTimer = nil
        afterPlayBlock?(.normal)
    }
}
