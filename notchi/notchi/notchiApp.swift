//
//  notchiApp.swift
//  rhythm
//
//  Created by Ruban on 2026-01-30.
//

import SwiftUI

@main
struct rhythmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
