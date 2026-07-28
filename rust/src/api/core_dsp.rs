use std::fs;
use std::process::Command;
use std::path::Path;
use std::env;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

// 🛠️ RESOLUTOR DINÁMICO: Busca FFmpeg en la carpeta del ejecutable
fn get_ffmpeg_path() -> String {
    if let Ok(mut exe_path) = env::current_exe() {
        exe_path.pop();
        exe_path.push(if cfg!(target_os = "windows") { "ffmpeg.exe" } else { "ffmpeg" });
        if exe_path.exists() {
            return exe_path.to_string_lossy().into_owned();
        }
    }
    "ffmpeg".to_string()
}

fn extract_json_value(log: &str, key: &str) -> Option<String> {
    let search_key = format!("\"{}\" : \"", key);
    if let Some(start) = log.find(search_key.as_str()) {
        let val_start = start + search_key.len();
        if let Some(end_offset) = log[val_start..].find('\"') {
            return Some(log[val_start..val_start + end_offset].to_string());
        }
    }
    None
}

fn atomic_replace(temp_path: &Path, original_path: &Path) -> Result<(), String> {
    fs::rename(temp_path, original_path).map_err(|e| format!("Fallo en I/O Atómico: {}", e))
}

pub async fn process_auto_trim(input_path: String) -> Result<bool, String> {
    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }

    let temp_path = input.with_file_name("temp_dsp_trim.mp3");
    let filter = "silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse";
    
    let output = Command::new(get_ffmpeg_path())
        .args(["-y", "-i", input.to_str().unwrap(), "-af", filter, "-c:a", "libmp3lame", "-q:a", "2", temp_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("OS Invocation Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub async fn inject_watermark(input_path: String) -> Result<bool, String> {
    let input = Path::new(&input_path);
    let temp_path = input.with_file_name("temp_watermark.mp3");

    let output = Command::new(get_ffmpeg_path())
        .args(["-y", "-i", input.to_str().unwrap(), "-map", "0", "-c", "copy", "-metadata", "DjStudio_M3_V2=Verified", temp_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("OS Invocation Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub async fn check_watermark(input_path: String) -> Result<bool, String> {
    let output = Command::new(get_ffmpeg_path())
        .args(["-i", &input_path, "-f", "ffmetadata", "-"])
        .output()
        .map_err(|e| format!("OS Invocation Error: {}", e))?;

    let log = format!("{}{}", String::from_utf8_lossy(&output.stderr), String::from_utf8_lossy(&output.stdout));
    Ok(log.contains("DjStudio_M3_V2=Verified"))
}

pub async fn normalize_lufs(input_path: String) -> Result<bool, String> {
    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }

    let null_sink = if cfg!(target_os = "windows") { "NUL" } else { "/dev/null" };

    let pass1_output = Command::new(get_ffmpeg_path())
        .args(["-i", input.to_str().unwrap(), "-af", "loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json", "-f", "null", null_sink])
        .output()
        .map_err(|e| format!("Paso 1 Error: {}", e))?;

    let log = String::from_utf8_lossy(&pass1_output.stderr);
    let i = extract_json_value(&log, "input_i").ok_or("input_i missing".to_string())?;
    let lra = extract_json_value(&log, "input_lra").ok_or("input_lra missing".to_string())?;
    let tp = extract_json_value(&log, "input_tp").ok_or("input_tp missing".to_string())?;
    let thresh = extract_json_value(&log, "input_thresh").ok_or("input_thresh missing".to_string())?;

    let temp_path = input.with_file_name("temp_dsp_norm.mp3");
    let pass2_filter = format!("loudnorm=I=-14:LRA=11:TP=-1.5:measured_I={}:measured_LRA={}:measured_TP={}:measured_thresh={}:linear=true", i, lra, tp, thresh);

    let pass2_output = Command::new(get_ffmpeg_path())
        .args(["-y", "-i", input.to_str().unwrap(), "-af", &pass2_filter, "-c:a", "libmp3lame", "-q:a", "2", temp_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("Paso 2 Error: {}", e))?;

    if pass2_output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&pass2_output.stderr).to_string())
    }
}

pub async fn process_full_pipeline(input_path: String) -> Result<bool, String> {
    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }
    let temp_path = input.with_file_name("temp_dsp_full.mp3");

    let filter = "loudnorm=I=-14:LRA=11:TP=-1.5,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse";

    let output = Command::new(get_ffmpeg_path())
        .args(["-y", "-i", input.to_str().unwrap(), "-af", filter, "-c:a", "libmp3lame", "-b:a", "320k", temp_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("OS Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub async fn clear_watermark(input_path: String) -> Result<bool, String> {
    let input = Path::new(&input_path);
    let temp_path = input.with_file_name("temp_clear_meta.mp3");

    let output = Command::new(get_ffmpeg_path())
        .args(["-y", "-i", input.to_str().unwrap(), "-map", "0", "-c", "copy", "-metadata", "DjStudio_M3=", "-metadata", "DjStudio_M3_V2=", temp_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("OS Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub async fn read_audio_genre(input_path: String) -> String {
    let output = Command::new(get_ffmpeg_path())
        .args(["-i", &input_path, "-f", "ffmetadata", "-"])
        .output();

    if let Ok(out) = output {
        let log = format!("{}{}", String::from_utf8_lossy(&out.stderr), String::from_utf8_lossy(&out.stdout));
        for line in log.to_lowercase().lines() {
            if line.starts_with("genre=") {
                return line.replace("genre=", "").trim().to_string();
            }
        }
    }
    "desconocido".to_string()
}