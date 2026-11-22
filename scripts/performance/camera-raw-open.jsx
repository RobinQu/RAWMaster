// Photoshop's public Camera RAW open interface. The caller supplies a disposable RAW copy.
(function (path, spatialFile, nativeSize, returnedMetadata) {
    var previousDialogs = app.displayDialogs;
    var doc = null;
    try {
        app.displayDialogs = DialogModes.NO;
        var options = new CameraRAWOpenOptions();
        options.settings = CameraRAWSettingsType.SELECTEDIMAGE;
        options.colorSpace = ColorSpaceType.SRGB;
        options.bitsPerChannel = BitsPerChannelType.EIGHT;
        var rawFile = new File(path);
        var reset = $.hiresTimer;
        doc = app.open(rawFile, options);
        var openMicros = $.hiresTimer;
        if (returnedMetadata) {
            var metadata = new File(returnedMetadata);
            try {
                metadata.encoding = "UTF8";
                if (!metadata.open("w") || !metadata.write(doc.xmpMetadata.rawData)) throw Error("Cannot save document XMP");
            } finally { metadata.close(); }
        }
        var result = [app.version, doc.width.as("px"), doc.height.as("px"), openMicros];
        for (var i = 0; i < 3; i++) result.push(doc.channels[i].histogram.join(","));
        if (spatialFile) {
            if (!nativeSize) doc.resizeImage(UnitValue(1024, "px"), null, null, ResampleMethod.BICUBIC);
            var bmp = new BMPSaveOptions();
            bmp.depth = BMPDepthType.TWENTYFOUR;
            bmp.osType = OperatingSystem.WINDOWS;
            bmp.rleCompression = false;
            doc.saveAs(new File(spatialFile), bmp, true, Extension.LOWERCASE);
        }
        return result.join("|");
    } finally {
        try {
            if (doc) doc.close(SaveOptions.DONOTSAVECHANGES);
        } finally {
            app.displayDialogs = previousDialogs;
        }
    }
})
