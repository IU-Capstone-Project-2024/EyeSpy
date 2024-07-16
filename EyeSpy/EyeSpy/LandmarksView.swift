//
//  LandmarksView.swift
//  ShadersFun
//
//  Created by Aleksandr Strizhnev on 26.06.2024.
//

import AVKit
import SwiftUI
import Combine
import Vision
import CreateML
import TabularData
import SpriteKit

class LandmarksViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isGranted: Bool = false

    var captureSession: AVCaptureSession!
    private var cancellables = Set<AnyCancellable>()
    private var request: DetectFaceLandmarksRequest
    private let videoDataOutputQueue = DispatchQueue(label: "CameraFeedDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    private let model: MLModel
    
    @Published var faceRect: NormalizedRect?
    @Published var landmarks: FaceObservation.Landmarks2D?
    @Published var frameSize: CGSize = .zero
    
    @Published var leftGaze: CGPoint?
    @Published var rightGaze: CGPoint?
    
    override init() {
        self.request = DetectFaceLandmarksRequest()
        model = try! Gaze().model
        
        super.init()
        
        captureSession = AVCaptureSession()
        setupBindings()
    }
    
    func setupBindings() {
        $isGranted
            .sink { [weak self] isGranted in
                if isGranted {
                    self?.prepareCamera()
                } else {
                    self?.stopSession()
                }
            }
            .store(in: &cancellables)
    }
    
    func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: // The user has previously granted access to the camera.
            self.isGranted = true
            
        case .notDetermined: // The user has not yet been asked for camera access.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.isGranted = granted
                    }
                }
            }
            
        case .denied: // The user has previously denied access.
            self.isGranted = false
            return
            
        case .restricted: // The user can't grant access due to restrictions.
            self.isGranted = false
            return
        @unknown default:
            fatalError()
        }
    }
    
    func startSession() {
        guard !captureSession.isRunning else { return }
        captureSession.sessionPreset = .vga640x480
        captureSession.startRunning()
    }
    
    func stopSession() {
        guard captureSession.isRunning else { return }
        captureSession.stopRunning()
    }
    
    func prepareCamera() {
        if let device = AVCaptureDevice.default(for: .video) {
            startSessionForDevice(device)
        }
    }
    
    func startSessionForDevice(_ device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            addInput(input)
            startSession()
        }
        catch {
            print("Something went wrong - ", error.localizedDescription)
        }
    }
    
    func addInput(_ input: AVCaptureInput) {
        guard captureSession.canAddInput(input) else {
            return
        }
        let dataOutput = AVCaptureVideoDataOutput()
        
        guard captureSession.canAddOutput(dataOutput) else {
            return
        }
        captureSession.addOutput(dataOutput)
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        captureSession.addInput(input)
        
        // set to kCVPixelFormatType_32BGRA
        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        dataOutput.videoSettings = videoSettings
        
        let connection = dataOutput.connection(with: .video)
        connection?.isVideoMirrored = true
        
        if let description = input.ports[0].formatDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            self.frameSize = CGSize(
                width: CGFloat(dimensions.width),
                height: CGFloat(dimensions.height)
            )
        }
    }
    
    func convertToGrayscale(image: NSImage) -> NSImage? {
        guard let tiffData = image.tiffRepresentation else { return nil }
        guard let bitmapImage = NSBitmapImageRep(data: tiffData) else { return nil }

        let ciImage = CIImage(bitmapImageRep: bitmapImage)
        let grayscaleFilter = CIFilter(name: "CIPhotoEffectMono")
        grayscaleFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        guard let outputImage = grayscaleFilter?.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: outputImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    func resizeImage(image: NSImage, newSize: NSSize) -> NSImage? {
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: newSize.width, height: newSize.height),
            from: NSRect.zero,
            operation: .copy,
            fraction: 1.0
        )
        scaledImage.unlockFocus()
        
        return scaledImage
    }
    
    func grayscaleImageToFloatArray(image: NSImage) -> [Float]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        
        // Draw the image in the context
        context.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )
        
        // Get the pixel data
        guard let pixelData = context.data else {
            return nil
        }
        
        // Convert the pixel data to an array of floats
        let data = pixelData.bindMemory(to: UInt8.self, capacity: width * height)
        var floatArray: [Float] = []
        for i in 0 ..< width * height {
            floatArray.append(Float(data[i]) / 255.0)  // Normalize the pixel value to [0, 1]
        }
        
        return floatArray
    }
    
    func createMLMultiArray(from floatArray: [Float], shape: [NSNumber]) -> MLMultiArray? {
        let count = shape.reduce(1) { $0 * $1.intValue }
        guard floatArray.count == count else {
            print("The number of elements in the array does not match the specified shape.")
            return nil
        }

        guard let mlMultiArray = try? MLMultiArray(shape: shape, dataType: .float32) else {
            print("Unable to create MLMultiArray.")
            return nil
        }

        floatArray.withUnsafeBufferPointer { bufferPointer in
            let dataPointer = mlMultiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
            dataPointer.update(from: bufferPointer.baseAddress!, count: count)
        }

        return mlMultiArray
    }
    
    func multiArrayToCGPoint(_ multiArray: MLMultiArray) -> CGPoint? {
        guard multiArray.shape.count == 2,
              multiArray.shape[0].intValue == 1,
              multiArray.shape[1].intValue == 2,
              multiArray.dataType == .float32 else {
            print("Invalid shape or data type")
            return nil
        }
        
        let dataPointer = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: 2)
        
        let x = CGFloat(dataPointer[1])
        let y = CGFloat(dataPointer[0])
        
        return CGPoint(x: x, y: y)
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task {
            guard let result = try await request.perform(on: sampleBuffer).first else {
                return
            }
            
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            CVPixelBufferLockBaseAddress(imageBuffer, CVPixelBufferLockFlags.readOnly)
            let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue
            bitmapInfo |= CGImageAlphaInfo.premultipliedFirst.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
            
            let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
            guard let quartzImage = context?.makeImage() else { return }
            
            if let landmarks = result.landmarks {
                let faceRect = result.boundingBox.toImageCoordinates(frameSize, origin: .upperLeft)
                
                let leftEyeRect = landmarks.leftEye.imageRect(
                    faceRect: faceRect
                )
                let rightEyeRect = landmarks.rightEye.imageRect(
                    faceRect: faceRect
                )
                
                guard let leftImage = quartzImage.cropping(to: leftEyeRect), let rightImage = quartzImage.cropping(to: rightEyeRect) else {
                    return
                }
                
                let leftEyeImage = NSImage(
                    cgImage: leftImage, size: .zero
                )
                let rightEyeImage = NSImage(
                    cgImage: rightImage, size: .zero
                )
                
                let eyeImageSize = NSSize(width: 160 / 2, height: 96 / 2)
                
                let scaledLeftImage = resizeImage(
                    image: convertToGrayscale(image: leftEyeImage)!,
                    newSize: eyeImageSize
                )!
                let scaledRightImage = resizeImage(
                    image: convertToGrayscale(image: rightEyeImage)!,
                    newSize: eyeImageSize
                )!
                
                let leftInput = grayscaleImageToFloatArray(image: scaledLeftImage)
                let rightInput = grayscaleImageToFloatArray(image: scaledRightImage)
                
                let leftEyeInput = try MLDictionaryFeatureProvider(
                    dictionary: [
                        "imgs": createMLMultiArray(from: leftInput!, shape: [1, 96, 160])
                    ]
                )
                let rightEyeInput = try MLDictionaryFeatureProvider(
                    dictionary: [
                        "imgs": createMLMultiArray(from: rightInput!, shape: [1, 96, 160])
                    ]
                )
  
                let leftOutput = try! await model.prediction(from: leftEyeInput).featureValue(for: "linear_1")
                let rightOutput = try! await model.prediction(from: leftEyeInput).featureValue(for: "linear_1")
                
                Task { @MainActor in
                    if let leftOutput {
                        self.leftGaze = multiArrayToCGPoint(leftOutput.multiArrayValue!)
                    }
                    if let rightOutput {
                        self.rightGaze = multiArrayToCGPoint(rightOutput.multiArrayValue!)
                    }
                }
            }
            
            Task { @MainActor in
                self.faceRect = result.boundingBox
                self.landmarks = result.landmarks
            }
        }
    }
}

struct LandmarksView: View {
    @ObservedObject private var viewModel = LandmarksViewModel()
    
    @State private var prevBlink = false
    
    init() {
        viewModel.checkAuthorization()
    }
    
    var body: some View {
        GeometryReader { windowProxy in
            ZStack {
                GeometryReader { proxy in
                    PlayerContainerView(captureSession: viewModel.captureSession)
                    
                    if let faceRect = viewModel.faceRect, let landmarks = viewModel.landmarks {
                        let boundingBox = CGSize(
                            width: faceRect.width * proxy.size.width,
                            height: faceRect.height * proxy.size.height
                        )
                        
                        Canvas { context, size in
                            landmarks.faceContour.draw(
                                in: context,
                                size: size,
                                closed: false
                            )
                            
                            landmarks.innerLips.draw(in: context, size: size)
                            landmarks.outerLips.draw(in: context, size: size)
                            
                            landmarks.leftEye.draw(in: context, size: size)
                            landmarks.leftEyebrow.draw(in: context, size: size)
                            
                            landmarks.rightEye.draw(in: context, size: size)
                            landmarks.rightEyebrow.draw(in: context, size: size)
                            
                            landmarks.nose.draw(in: context, size: size)
                            landmarks.noseCrest.draw(
                                in: context,
                                size: size,
                                closed: false
                            )
                            
                            landmarks.leftPupil.drawDots(in: context, size: size)
                            landmarks.rightPupil.drawDots(in: context, size: size)
                            
                            if let leftGaze = viewModel.leftGaze {
                                leftGaze.drawGaze(in: context, from: landmarks.leftPupil, size: size)
                            }
                            
                            if let rightGaze = viewModel.rightGaze {
                                rightGaze.drawGaze(in: context, from: landmarks.rightPupil, size: size)
                            }
                        }
                        .frame(
                            width: boundingBox.width,
                            height: boundingBox.height
                        )
                        .offset(
                            CGSize(
                                width: faceRect.origin.x * proxy.size.width,
                                height: (1 - faceRect.origin.y - faceRect.height) * proxy.size.height
                            )
                        )
                    }
                }
                .frame(
                    width: aspectFit(viewModel.frameSize, in: windowProxy.size).width,
                    height: aspectFit(viewModel.frameSize, in: windowProxy.size).height
                )
                
                if let leftGaze = viewModel.leftGaze {
                    Circle()
                        .fill(.blue.opacity(0.5))
                        .frame(
                            width: 200,
                            height: 200
                        )
                        .position(
                            leftGaze.attentionPoint(windowSize: windowProxy.size)
                        )
                }
                
                if let rightGaze = viewModel.leftGaze {
                    Circle()
                        .fill(.blue.opacity(0.5))
                        .frame(
                            width: 200,
                            height: 200
                        )
                        .position(
                            rightGaze.attentionPoint(windowSize: windowProxy.size)
                        )
                }
            }
            .frame(
                width: windowProxy.size.width,
                height: windowProxy.size.height
            )
        }
    }
}

extension CGPoint {
    func drawGaze(in context: GraphicsContext, from pupil: FaceObservation.Landmarks2D.Region, size: CGSize) {
        let points = pupil.pointsInBoundingBox(size)
        
        let length = 60.0

        let dx = -length * Foundation.sin(self.x)
        let dy = length * Foundation.sin(self.y)
        
        var line = Path()
        
        line.move(to: points[0])
        line.addLine(
            to: CGPoint(
                x: points[0].x + dx,
                y: points[0].y + dy
            )
        )
        
        context.stroke(
            line,
            with: .color(.blue),
            lineWidth: 2
        )
    }
    
    func attentionPoint(windowSize: CGSize) -> CGPoint {
        let rad = max(windowSize.width, windowSize.height)
        
        let dx = -rad * Foundation.sin(self.x)
        let dy = rad * Foundation.sin(self.y)
        
        return CGPoint(
            x: windowSize.width / 2 + dx,
            y: windowSize.height / 2 + dy
        )
    }
}

extension FaceObservation.Landmarks2D.Region {
    func pointsInBoundingBox(_ boundingBox: CGSize) -> [CGPoint] {
        return points.map { point in
            CGPoint(
                x: point.x * boundingBox.width,
                y: (1 - point.y) * boundingBox.height
            )
        }
    }
    
    func draw(in context: GraphicsContext, size: CGSize, closed: Bool = true) {
        let points = pointsInBoundingBox(size)

        var line = Path()
        
        line.move(to: points[0])
        for index in 1..<points.count {
            line.addLine(to: points[index])
        }
        if closed {
            line.addLine(to: points[0])
        }
        
        context.stroke(
            line,
            with: .color(.red),
            lineWidth: 2
        )
    }
    
    func drawDots(in context: GraphicsContext, size: CGSize) {
        let points = pointsInBoundingBox(size)

        for point in points {
            let rect = CGRect(
                origin: point,
                size: .init(width: 4, height: 4)
            )

            let path = Circle().path(in: rect)
            context.fill(path, with: .color(.red))
        }
    }
    
    func imageRect(faceRect: CGRect) -> CGRect {
        let points = pointsInBoundingBox(faceRect.size).map {
            CGPoint(
                x: $0.x + faceRect.origin.x,
                y: $0.y + faceRect.origin.y
            )
        }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        
        let minX = xs.min()!
        let minY = ys.min()!
        let maxX = xs.max()!
        let maxY = ys.max()!
        
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).insetBy(
            dx: -10,
            dy: -10
        )
    }
}

func aspectFit(_ frame: CGSize, in bounds: CGSize) -> CGSize {
    AVMakeRect(
        aspectRatio: frame, insideRect: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    ).size
}

#Preview {
    LandmarksView()
}
