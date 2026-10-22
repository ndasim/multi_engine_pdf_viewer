Pod::Spec.new do |s|
  s.name             = 'multi_engine_pdf_viewer'
  s.version          = '0.2.0'
  s.summary          = 'Engine-independent PDF viewing with an iOS PDFKit adapter.'
  s.description      = 'Local PDF rendering, navigation, search, outlines and links using Apple PDFKit.'
  s.homepage         = 'https://github.com/ndasim/multi_engine_pdf_viewer'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'multi_engine_pdf_viewer contributors' => 'https://github.com/ndasim/multi_engine_pdf_viewer' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'PDFKit', 'UIKit'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
