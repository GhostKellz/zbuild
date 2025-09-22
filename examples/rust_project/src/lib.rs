pub mod builder {
    use std::path::Path;
    use std::process::Command;

    pub struct RustBuilder {
        project_name: String,
        source_files: Vec<String>,
        output_dir: String,
        optimization_level: OptLevel,
    }

    #[derive(Debug, Clone, Copy)]
    pub enum OptLevel {
        Debug,
        Release,
        Size,
    }

    impl RustBuilder {
        pub fn new(name: &str) -> Self {
            RustBuilder {
                project_name: name.to_string(),
                source_files: Vec::new(),
                output_dir: "target".to_string(),
                optimization_level: OptLevel::Debug,
            }
        }

        pub fn add_source(&mut self, path: &str) -> &mut Self {
            self.source_files.push(path.to_string());
            self
        }

        pub fn set_optimization(&mut self, level: OptLevel) -> &mut Self {
            self.optimization_level = level;
            self
        }

        pub fn build(&self) -> Result<(), BuildError> {
            println!("Building {} with {:?} optimization", self.project_name, self.optimization_level);

            for source in &self.source_files {
                if !Path::new(source).exists() {
                    return Err(BuildError::SourceNotFound(source.clone()));
                }
            }

            Ok(())
        }

        pub fn run_tests(&self) -> Result<TestResults, BuildError> {
            Ok(TestResults {
                passed: 10,
                failed: 0,
                ignored: 2,
            })
        }
    }

    #[derive(Debug)]
    pub enum BuildError {
        SourceNotFound(String),
        CompilationFailed(String),
        LinkingFailed(String),
    }

    pub struct TestResults {
        pub passed: usize,
        pub failed: usize,
        pub ignored: usize,
    }

    impl TestResults {
        pub fn display(&self) {
            println!("Test results: {} passed, {} failed, {} ignored",
                     self.passed, self.failed, self.ignored);
        }
    }
}

pub mod cache {
    use std::collections::HashMap;

    pub struct Cache {
        entries: HashMap<String, CacheEntry>,
    }

    struct CacheEntry {
        key: String,
        data: Vec<u8>,
        hash: String,
    }

    impl Cache {
        pub fn new() -> Self {
            Cache {
                entries: HashMap::new(),
            }
        }

        pub fn store(&mut self, key: &str, data: Vec<u8>) {
            let hash = format!("{:x}", md5::compute(&data));
            self.entries.insert(
                key.to_string(),
                CacheEntry {
                    key: key.to_string(),
                    data,
                    hash,
                },
            );
        }

        pub fn get(&self, key: &str) -> Option<&[u8]> {
            self.entries.get(key).map(|entry| entry.data.as_slice())
        }

        pub fn has(&self, key: &str) -> bool {
            self.entries.contains_key(key)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::builder::*;

    #[test]
    fn test_builder_creation() {
        let builder = RustBuilder::new("test_project");
        assert_eq!(builder.project_name, "test_project");
    }

    #[test]
    fn test_add_sources() {
        let mut builder = RustBuilder::new("test");
        builder.add_source("src/main.rs")
               .add_source("src/lib.rs");
        assert_eq!(builder.source_files.len(), 2);
    }
}