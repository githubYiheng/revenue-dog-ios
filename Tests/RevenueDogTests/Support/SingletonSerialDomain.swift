//
//  SingletonSerialDomain.swift
//  跨 suite 竞态的修复点。
//
//  背景：`Purchases` 是**静态单例**，凡是调 `Purchases.configure(...)` /
//  `Purchases.resetForTesting()` 的 suite 都在写同一份全局状态。Swift Testing 默认
//  **并行执行不同 suite**，而 `.serialized` 只在 suite **内部**串行 —— 于是
//  A suite 的 `resetForTesting()` 会把 B suite 刚配置好的单例掀掉，
//  偶发表现为 `Purchases.isConfigured == false` / `Purchases.shared` fatalError。
//
//  修法（最小改动、零生产代码语义变更）：把所有碰单例的 suite 作为**嵌套 suite**
//  挂到这一个父 suite 下，父 suite 带 `.serialized`。该 trait 会**递归**作用到
//  所有后代 suite 与测试上 —— 于是这些 suite 之间也串行，单例同一时刻只有一个主人。
//  （嵌套关系由类型的词法包含决定，所以各测试文件用 `extension` 把 suite 声明进来。）
//
//  代价：这些 suite 不再互相并行。它们本来就在抢同一个单例，并行本就是假的。
//

import Testing

@Suite("单例串行域", .serialized)
enum PurchasesSingletonDomain {}
