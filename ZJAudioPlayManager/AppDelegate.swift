//
//  AppDelegate.swift
//  ZJAudioPlayManager
//
//  Created by Howard-Zjun on 2025/4/26.
//

import UIKit

var isForeground = true

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let rootVC = ViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        isForeground = true
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        isForeground = false
    }
}

