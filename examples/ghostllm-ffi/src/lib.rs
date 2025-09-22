use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use serde::{Deserialize, Serialize};

/// Represents a chat request to the LLM
#[derive(Debug, Serialize, Deserialize)]
pub struct ChatRequest {
    pub prompt: String,
    pub max_tokens: u32,
    pub temperature: f32,
}

/// Represents a response from the LLM
#[derive(Debug, Serialize, Deserialize)]
pub struct ChatResponse {
    pub content: String,
    pub tokens_used: u32,
    pub finish_reason: String,
}

/// Opaque handle to the GhostLLM instance
pub struct GhostLLM {
    model_path: String,
    initialized: bool,
}

impl GhostLLM {
    pub fn new(model_path: &str) -> Self {
        Self {
            model_path: model_path.to_string(),
            initialized: false,
        }
    }

    pub fn init(&mut self) -> Result<(), &'static str> {
        // Simulate model initialization
        println!("Initializing GhostLLM with model: {}", self.model_path);
        self.initialized = true;
        Ok(())
    }

    pub fn chat_completion(&self, request: &ChatRequest) -> Result<ChatResponse, &'static str> {
        if !self.initialized {
            return Err("GhostLLM not initialized");
        }

        // Simulate AI processing
        let response = ChatResponse {
            content: format!("AI Response to: {} [temp={}]", request.prompt, request.temperature),
            tokens_used: request.max_tokens.min(150), // Simulate token usage
            finish_reason: "length".to_string(),
        };

        Ok(response)
    }
}

// C FFI exports
#[cfg(feature = "ffi")]
pub mod ffi {
    use super::*;
    use std::ptr;

    /// Initialize a new GhostLLM instance
    /// Returns: Pointer to GhostLLM instance, or null on failure
    #[no_mangle]
    pub extern "C" fn ghostllm_init(model_path: *const c_char) -> *mut GhostLLM {
        if model_path.is_null() {
            return ptr::null_mut();
        }

        let c_str = unsafe { CStr::from_ptr(model_path) };
        let path_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        };

        let mut instance = Box::new(GhostLLM::new(path_str));
        match instance.init() {
            Ok(_) => Box::into_raw(instance),
            Err(_) => ptr::null_mut(),
        }
    }

    /// Process a chat completion request
    /// Returns: JSON string response, or null on failure
    #[no_mangle]
    pub extern "C" fn ghostllm_chat_completion(
        instance: *mut GhostLLM,
        request_json: *const c_char,
    ) -> *mut c_char {
        if instance.is_null() || request_json.is_null() {
            return ptr::null_mut();
        }

        let ghostllm = unsafe { &*instance };
        let c_str = unsafe { CStr::from_ptr(request_json) };
        let json_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        };

        let request: ChatRequest = match serde_json::from_str(json_str) {
            Ok(req) => req,
            Err(_) => return ptr::null_mut(),
        };

        let response = match ghostllm.chat_completion(&request) {
            Ok(resp) => resp,
            Err(_) => return ptr::null_mut(),
        };

        let response_json = match serde_json::to_string(&response) {
            Ok(json) => json,
            Err(_) => return ptr::null_mut(),
        };

        match CString::new(response_json) {
            Ok(c_string) => c_string.into_raw(),
            Err(_) => ptr::null_mut(),
        }
    }

    /// Free a string returned by ghostllm_chat_completion
    #[no_mangle]
    pub extern "C" fn ghostllm_free_string(s: *mut c_char) {
        if !s.is_null() {
            unsafe {
                let _ = CString::from_raw(s);
            }
        }
    }

    /// Destroy a GhostLLM instance
    #[no_mangle]
    pub extern "C" fn ghostllm_destroy(instance: *mut GhostLLM) {
        if !instance.is_null() {
            unsafe {
                let _ = Box::from_raw(instance);
            }
        }
    }

    /// Get last error message
    #[no_mangle]
    pub extern "C" fn ghostllm_last_error() -> *const c_char {
        // In a real implementation, this would return thread-local error state
        b"No error\0".as_ptr() as *const c_char
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ghostllm_basic() {
        let mut llm = GhostLLM::new("test-model.bin");
        assert!(llm.init().is_ok());

        let request = ChatRequest {
            prompt: "Hello, world!".to_string(),
            max_tokens: 100,
            temperature: 0.7,
        };

        let response = llm.chat_completion(&request);
        assert!(response.is_ok());

        let resp = response.unwrap();
        assert!(resp.content.contains("Hello, world!"));
        assert_eq!(resp.tokens_used, 100);
    }
}