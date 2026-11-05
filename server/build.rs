fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut config = prost_build::Config::new();
    config.protoc_executable(protoc_bin_vendored::protoc_bin_path()?);
    tonic_prost_build::configure().compile_with_config(
        config,
        &["../proto/louie/linn/v1/linn.proto"],
        &[
            "../proto",
            protoc_bin_vendored::include_path()?
                .to_str()
                .ok_or("invalid protoc include path")?,
        ],
    )?;
    println!("cargo:rerun-if-changed=../proto/louie/linn/v1/linn.proto");
    Ok(())
}
