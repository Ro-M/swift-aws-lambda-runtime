//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAwsLambda open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftAwsLambda project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAwsLambda project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import NIO

/// LambdaRunner manages the Lambda runtime workflow, or business logic.
internal final class LambdaRunner {
    private let runtimeClient: LambdaRuntimeClient
    private let lambdaHandler: LambdaHandler
    private let eventLoop: EventLoop
    private let lifecycleId: String

    init(eventLoop: EventLoop, config: Lambda.Config, lambdaHandler: LambdaHandler) {
        self.eventLoop = eventLoop
        self.runtimeClient = LambdaRuntimeClient(eventLoop: self.eventLoop, config: config.runtimeEngine)
        self.lambdaHandler = lambdaHandler
        self.lifecycleId = config.lifecycle.id
    }

    /// Run the user provided initializer. This *must* only be called once.
    ///
    /// - Returns: An `EventLoopFuture<Void>` fulfilled with the outcome of the initialization.
    func initialize(logger: Logger) -> EventLoopFuture<Void> {
        logger.info("initializing lambda")
        // We need to use `flatMap` instead of `whenFailure` to ensure we complete reporting the result before stopping.
        return self.lambdaHandler.initialize(eventLoop: self.eventLoop, lifecycleId: self.lifecycleId).peekError { error in
            self.runtimeClient.reportInitializationError(logger: logger, error: error).peekError { reportingError in
                // We're going to bail out because the init failed, so there's not a lot we can do other than log
                // that we couldn't report this error back to the runtime.
                logger.error("failed reporting initialization error to lambda runtime engine: \(reportingError)")
            }
        }
    }

    func run(logger: Logger) -> EventLoopFuture<Void> {
        logger.info("lambda invocation sequence starting")
        // 1. request work from lambda runtime engine
        return self.runtimeClient.requestWork(logger: logger).peekError { error in
            logger.error("could not fetch work from lambda runtime engine: \(error)")
        }.flatMap { context, payload in
            // 2. send work to handler
            logger.info("sending work to lambda handler \(self.lambdaHandler)")
            return self.lambdaHandler.handle(eventLoop: self.eventLoop, lifecycleId: self.lifecycleId, context: context, payload: payload).map { (context, $0) }
        }.flatMap { context, result in
            // 3. report results to runtime engine
            self.runtimeClient.reportResults(logger: logger, context: context, result: result).peekError { error in
                logger.error("failed reporting results to lambda runtime engine: \(error)")
            }
        }.always { result in
            // we are done!
            logger.info("lambda invocation sequence completed \(result.successful ? "successfully" : "with failure")")
        }
    }
}

private extension LambdaHandler {
    func initialize(eventLoop: EventLoop, lifecycleId: String) -> EventLoopFuture<Void> {
        // offloading so user code never blocks the eventloop
        let promise = eventLoop.makePromise(of: Void.self)
        DispatchQueue(label: "lambda-\(lifecycleId)").async {
            self.initialize { promise.completeWith($0) }
        }
        return promise.futureResult
    }

    func handle(eventLoop: EventLoop, lifecycleId: String, context: LambdaContext, payload: [UInt8]) -> EventLoopFuture<LambdaResult> {
        // offloading so user code never blocks the eventloop
        let promise = eventLoop.makePromise(of: LambdaResult.self)
        DispatchQueue(label: "lambda-\(lifecycleId)").async {
            self.handle(context: context, payload: payload) { result in
                promise.succeed(result)
            }
        }
        return promise.futureResult
    }
}

// TODO: move to nio?
private extension EventLoopFuture {
    // callback does not have side effects, failing with original result
    func peekError(_ callback: @escaping (Error) -> Void) -> EventLoopFuture<Value> {
        return self.flatMapError { error in
            callback(error)
            return self
        }
    }

    // callback does not have side effects, failing with original result
    func peekError(_ callback: @escaping (Error) -> EventLoopFuture<Void>) -> EventLoopFuture<Value> {
        return self.flatMapError { error in
            let promise = self.eventLoop.makePromise(of: Value.self)
            callback(error).whenComplete { _ in
                promise.completeWith(self)
            }
            return promise.futureResult
        }
    }
}

private extension Result {
    var successful: Bool {
        switch self {
        case .success:
            return true
        default:
            return false
        }
    }
}