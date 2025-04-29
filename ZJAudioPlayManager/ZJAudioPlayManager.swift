//
//  ZJAudioPlayManager.swift
//  ListenSpeak
//
//  Created by Howard-Zjun on 2025/2/24.
//

import UIKit
import AVFoundation
import Alamofire
import CryptoKit

let CACHE_BASE_PATH = NSHomeDirectory() + "/Library/Caches"

enum AudioMode {
    case localAudio(resourceName: String, mineType: String)
    case audioPath(urlStr: String, preDownload: Bool)
    case audioURL(url: URL, preDownload: Bool)
}

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

    var modes: [AudioMode] = []
    
    var nowIndex: Int?
    
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
    
    // MARK: - 单个资源播放
    func playAudio(resourceName: String, mineType: String, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        print("[\(#file):\(#line)] \(#function) 播放本地音频: \(resourceName).\(mineType)")
        let mode = AudioMode.localAudio(resourceName: resourceName, mineType: mineType)
        playAudio(modes: [mode], beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
    }
    
    func playAudio(urlStr: String, preDownload: Bool = false, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        print("[\(#file):\(#line)] \(#function) 播放音频链接: \(urlStr)")
        let mode = AudioMode.audioPath(urlStr: urlStr, preDownload: preDownload)
        playAudio(modes: [mode], beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
    }
    
    func playAudio(url: URL, preDownload: Bool = false, beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        print("[\(#file):\(#line)] \(#function) 播放音频路径: \(url.absoluteString)")
        let mode = AudioMode.audioURL(url: url, preDownload: preDownload)
        playAudio(modes: [mode], beforePlayBlock: beforePlayBlock, afterPlayBlock: afterPlayBlock, progressBlock: progressBlock)
    }
    
    // MARK: - 多个资源播放
    func playAudio(modes: [AudioMode], beforePlayBlock: (() -> Void)? = nil, afterPlayBlock: ((EndType) -> Void)? = nil, progressBlock: ((TimeInterval) -> Void)? = nil) {
        // 处理正在播放的情况
        if let player, player.isPlaying, !isPlayEnd {
            let afterPlayBlock = self.afterPlayBlock
            cleanData()
            afterPlayBlock?(.playOther)
        }
        
        let nowIndex = 0
        self.nowIndex = nowIndex
        self.modes = modes
        self.beforePlayBlock = beforePlayBlock
        self.afterPlayBlock = afterPlayBlock
        self.progressBlock = progressBlock
        playAudio(mode: modes[nowIndex])
        
        for mode in modes {
            if case .audioPath(let urlStr, let preDownload) = mode {
                if preDownload {
                    if urlStr.hasPrefix("http"), let url = URL(string: urlStr){
                        downloadAudio(url: url)
                    }
                }
            } else if case .audioURL(let url, let preDownload) = mode {
                if preDownload {
                    downloadAudio(url: url)
                }
            }
        }
    }
    
    private func playAudio(mode: AudioMode) {
        player = nil
        if case .localAudio(let resourceName, let mineType) = mode {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: mineType) else {
                print("[\(#file):\(#line)] \(#function) 本地音频资源不存在")
                if modes.count == 1 {
                    afterPlayBlock?(.normal)
                }
                return
            }
            
            playAudio(url: url)
        } else if case .audioPath(let urlStr, let preDownload) = mode {
            if urlStr.hasPrefix("http") {
                if let url = URL(string: urlStr) {
                    if preDownload {
                        audioURL = url
                        // 等待下载完成继续播放
                    } else {
                        playAudio(url: url)
                    }
                } else {
                    let afterPlayBlock = self.afterPlayBlock
                    cleanData()
                    afterPlayBlock?(.notAudio)
                }
            } else {
                if FileManager.default.fileExists(atPath: urlStr) {
                    let url = URL(fileURLWithPath: urlStr)
                    playAudio(url: url)
                } else {
                    let afterPlayBlock = self.afterPlayBlock
                    cleanData()
                    afterPlayBlock?(.notAudio)
                }
            }
        } else if case .audioURL(let url, let preDownload) = mode {
            if preDownload {
                audioURL = url
                // 等待下载完成继续播放
            } else {
                playAudio(url: url)
            }
        }
    }
    
    func pauseAudio() {
        pauseHandle()
    }
    
    func stopAudio() {
        stopHandle()
    }
    
    private func playAudio(url: URL) {
        self.audioURL = url
     
        if !url.absoluteString.hasPrefix("http") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                playAudio(player: player)
            } catch {
                print("[\(#file):\(#line)] \(#function) error: \(error)")
                let afterPlayBlock = self.afterPlayBlock
                cleanData()
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
                    DispatchQueue.main.async { [weak self] in
                        print("[\(#file):\(#line) \(#function) error: \(error)")
                        let afterPlayBlock = self?.afterPlayBlock
                        self?.cleanData()
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
            let afterPlayBlock = self.afterPlayBlock
            cleanData()
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
    
    private func downloadAudio(url: URL) {
        print("[\(#file):\(#line) \(#function) 下载: \(url)")
        
        guard url.absoluteString.hasPrefix("http") else {
            print("[\(#file):\(#line)] \(#function) 不是网络链接")
            if audioURL == url && player == nil {
                playAudio(url: url)
            }
            return
        }
        let savePath = filePath(url: url)
        let locationURL = URL(fileURLWithPath: savePath)
        
        if FileManager.default.fileExists(atPath: savePath) {
            print("[\(#file):\(#function)]-\(#line) 文件已存在")
            if audioURL == url && player == nil {
                playAudio(url: locationURL)
            }
        } else {
            let request = AF.download(url.absoluteString, to: { temporaryURL, response in
                return (locationURL, [.removePreviousFile, .createIntermediateDirectories])
            })
            request.response { [weak self] response in
                print("[\(#file):\(#line)] \(#function) 下载完成")
                if self?.audioURL == url && self?.player == nil {
                    self?.playAudio(url: locationURL)
                }
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
        isPlayEnd = true
        cleanData()
    }
    
    private func filePath(url: URL) -> String {
        let digest = Insecure.MD5.hash(data: url.absoluteString.data(using: .utf8) ?? Data())
        let str = digest.map { String(format: "%02x", $0) }.joined()
        return folderPath + "/" + str + "." + url.pathExtension
    }
    
    func cleanData() {
        currentTimer?.invalidate()
        currentTimer = nil
        modes = []
        nowIndex = nil
        audioURL = nil
        player?.stop()
        player = nil
        beforePlayBlock = nil
        afterPlayBlock = nil
        progressBlock = nil
    }
}

// MARK: - AVAudioPlayerDelegate
extension ZJAudioPlayManager: AVAudioPlayerDelegate {
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let nowIndex, nowIndex + 1 < modes.count {
            print("[\(#file):\(#line)] \(#function) 播放下一个")
            self.nowIndex = nowIndex + 1
            playAudio(mode: modes[nowIndex + 1])
        } else {
            print("[\(#file):\(#line)] \(#function) 播放结束")
            isPlayEnd = true
            let afterPlayBlock = self.afterPlayBlock
            cleanData()
            afterPlayBlock?(.normal)
        }
    }
}
