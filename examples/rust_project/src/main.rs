use std::collections::HashMap;

fn main() {
    println!("zbuild Rust Example");
    println!("===================");

    let mut stats = Stats::new();
    stats.add_value("builds", 42);
    stats.add_value("tests", 128);
    stats.add_value("cache_hits", 89);

    stats.display();

    let result = fibonacci(10);
    println!("\nFibonacci(10) = {}", result);

    demonstrate_features();
}

struct Stats {
    data: HashMap<String, i32>,
}

impl Stats {
    fn new() -> Self {
        Stats {
            data: HashMap::new(),
        }
    }

    fn add_value(&mut self, key: &str, value: i32) {
        self.data.insert(key.to_string(), value);
    }

    fn display(&self) {
        println!("\nBuild Statistics:");
        for (key, value) in &self.data {
            println!("  {}: {}", key, value);
        }
    }
}

fn fibonacci(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        _ => fibonacci(n - 1) + fibonacci(n - 2),
    }
}

fn demonstrate_features() {
    println!("\nSupported Features:");

    let features = vec![
        "Incremental compilation",
        "Cross-compilation support",
        "Dependency management",
        "Remote caching",
        "Multiple language support",
    ];

    for (i, feature) in features.iter().enumerate() {
        println!("  {}. {}", i + 1, feature);
    }

    let languages = ["C", "C++", "Zig", "Rust"];
    println!("\nSupported Languages: {:?}", languages);
}