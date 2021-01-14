//
//  AVPlayerViewController.swift
//  streamTest
//
//  Created by Edgars Ozolnieks on 02/11/2020.
//

import Foundation
import UIKit
import AVKit

class PlayerViewController: AVPlayerViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()

        let value = "https://test-tve-edgeware.helio.lv/__cl/s:ott-storage-01/__c/v/2/1/6/v_hn_sf_deadpool__216c1bc24ba0b680d8e71f02c2174d66/__op/hls-fairplay/__f/index.m3u8"
        
        guard let url = URL(string: value) else {
            return self.dismiss(animated: true, completion: nil)
        }
        
        let urlAsset = AVURLAsset(url: url)
        ContentKeyManager.shared.contentKeySession.addContentKeyRecipient(urlAsset)
        
        let playerItem = AVPlayerItem(asset: urlAsset)
        self.player = AVPlayer(playerItem: playerItem)
        
        //self.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        self.player?.play()
    }
}
