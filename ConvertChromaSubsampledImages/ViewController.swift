//
//  ViewController.swift
//  ConvertChromaSubsampledImages
//
//  Created by mark lim pak mun on 06/05/2024.
//  Copyright © 2024 Incremental Innovations. All rights reserved.
//

import AppKit

class ViewController: NSViewController
{

    @IBOutlet var imageView: NSImageView!
    @IBOutlet var saturationSlider: NSSlider!

    var cgImage: CGImage!
    var chromaSampler: ChromaSubsampler!

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let cgImage = loadImage()
        else {
            return
        }
        self.cgImage = cgImage
        chromaSampler = ChromaSubsampler(cgImage: cgImage)
        if chromaSampler.convert() {
            chromaSampler.applySaturation(0.25)
            self.cgImage = chromaSampler.result()
            update()
        }
        else {
            fatalError("Could not convert RGB to YpCbCr colour format")
        }
    }

    override var representedObject: Any? {
        didSet {
        }
    }

    // Also called on deminimising the window.
    override func viewDidAppear()
    {
    }

    func loadImage() -> CGImage?
    {
        guard let url = Bundle.main.urlForImageResource("Hibiscus.png")
        else {
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }

        let options = [
            kCGImageSourceShouldCache as String : true,
            kCGImageSourceShouldAllowFloat as String : true,
        ] as CFDictionary

        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options)
        else {
            return nil
        }
        // bitmapInfo - non-premultiplied RGBA
        return image
    }
    
    @IBAction func actionSlider(_ slider: NSSlider)
    {
        let value = slider.floatValue
        chromaSampler.applySaturation(value)
        self.cgImage = chromaSampler.result()
        update()
    }

    func update()
    {
        DispatchQueue.main.async {
            self.imageView.image = NSImage(cgImage: self.cgImage,
                                           size: NSZeroSize)
        }
    }
}

