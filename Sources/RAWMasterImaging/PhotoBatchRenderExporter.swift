import Foundation
import CoreImage
import RAWMasterCore

public struct PhotoBatchExportConfiguration:Equatable,Sendable{
  public var format:PhotoRenderFormat
  public var maximumLongEdge:Int?
  public var jpegQuality:Double
  public init(format:PhotoRenderFormat = .jpeg8,maximumLongEdge:Int? = nil,jpegQuality:Double = 0.9){
    self.format=format;self.maximumLongEdge=maximumLongEdge;self.jpegQuality=jpegQuality
  }
  public func validate()throws{
    guard jpegQuality.isFinite,(0.05...1).contains(jpegQuality)else{throw EditingError.invalidRecipe}
    if let maximumLongEdge{guard (64...100000).contains(maximumLongEdge)else{throw DevelopmentError.invalidGeometry}}
  }
}

public actor PhotoBatchRenderExporter{
  public init(){}
  public func export(work:PhotoWork,version:EditingVersion,archive:EditingArchive,directory:URL,filename:String,
                     configuration:PhotoBatchExportConfiguration,protectedURLs:[URL]=[])async throws->URL{
    try configuration.validate();let sanitized=URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent
    guard !sanitized.isEmpty,sanitized != ".",sanitized != ".."else{throw EditingError.unsafePath}
    let temporary=directory.appendingPathComponent(".rawmaster-export-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false)
    defer{try?FileManager.default.removeItem(at:temporary)}
    let rendered=temporary.appendingPathComponent("render.png")
    _=try await RenderExportService().export(work:work,version:version,archive:archive,destination:rendered,format:.png16,protectedURLs:protectedURLs)
    guard var image=CIImage(contentsOf:rendered,options:[.applyOrientationProperty:true]),!image.extent.isEmpty else{throw DevelopmentError.unreadable}
    image=image.transformed(by:.init(translationX:-image.extent.minX,y:-image.extent.minY))
    if let limit=configuration.maximumLongEdge{
      let scale=min(1,Double(limit)/max(image.extent.width,image.extent.height))
      if scale<1{image=image.transformed(by:.init(scaleX:scale,y:scale))}
    }
    let final=directory.appendingPathComponent(sanitized).appendingPathExtension(configuration.format.filenameExtension)
    try RenderFiles.check(final,protected:protectedURLs+[work.source.sourceLocation,archive.root])
    let stage=directory.appendingPathComponent(".rawmaster-render-"+UUID().uuidString).appendingPathExtension(configuration.format.filenameExtension)
    defer{try?FileManager.default.removeItem(at:stage)}
    let context=CIContext(options:[.cacheIntermediates:false]);defer{context.clearCaches()}
    let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
    switch configuration.format{
    case .jpeg8:
      image=image.composited(over:CIImage(color:.white).cropped(to:image.extent))
      try context.writeJPEGRepresentation(of:image,to:stage,colorSpace:colorSpace,options:[CIImageRepresentationOption(rawValue:kCGImageDestinationLossyCompressionQuality as String):configuration.jpegQuality])
    case .tiff16:try context.writeTIFFRepresentation(of:image,to:stage,format:.RGBA16,colorSpace:colorSpace,options:[:])
    case .png16:try context.writePNGRepresentation(of:image,to:stage,format:.RGBA16,colorSpace:colorSpace)
    }
    try Task.checkCancellation();try RenderFiles.check(final,protected:protectedURLs+[work.source.sourceLocation,archive.root])
    try FileManager.default.moveItem(at:stage,to:final);return final
  }
}
