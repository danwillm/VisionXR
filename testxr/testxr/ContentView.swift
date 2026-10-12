//
//  ContentView.swift
//  testxr
//
//  Created by danw on 12/10/2026.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: .main)
                .padding(.bottom, 50)

            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
}
