// Copyright 2026 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
package com.google.devtools.build.lib.runtime;

import com.google.common.flogger.GoogleLogger;
import java.time.Duration;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import javax.annotation.Nullable;

/** Invocation-scoped cache trimming when a runtime cannot report GC events. */
final class HeapPressureMonitor implements AutoCloseable {
  private static final GoogleLogger logger = GoogleLogger.forEnclosingClass();

  record HeapUsage(long used, long max) {}

  private final Supplier<HeapUsage> heap;
  private final LongSupplier nanoTime;
  private final Runnable dropCaches;
  private final int threshold;
  private final int maxDrops;
  private final long sustainedNanos;
  private final long cooldownNanos;
  @Nullable private ScheduledExecutorService scheduler;
  private boolean closed;
  private boolean underPressure;
  private long pressureStarted;
  private long lastDrop;
  private int drops;

  HeapPressureMonitor(
      Supplier<HeapUsage> heap,
      LongSupplier nanoTime,
      Runnable dropCaches,
      int threshold,
      int maxDrops,
      Duration sustained,
      Duration cooldown) {
    this.heap = heap;
    this.nanoTime = nanoTime;
    this.dropCaches = dropCaches;
    this.threshold = threshold;
    this.maxDrops = maxDrops;
    this.sustainedNanos = sustained.toNanos();
    this.cooldownNanos = cooldown.toNanos();
  }

  static HeapPressureMonitor start(MemoryPressureOptions options, Runnable dropCaches) {
    Runtime runtime = Runtime.getRuntime();
    HeapPressureMonitor monitor =
        new HeapPressureMonitor(
            () -> new HeapUsage(runtime.totalMemory() - runtime.freeMemory(), runtime.maxMemory()),
            System::nanoTime,
            dropCaches,
            options.nativeHeapPressureThreshold,
            options.nativeHeapPressureMaxDrops,
            Duration.ofSeconds(3),
            Duration.ofSeconds(30));
    monitor.scheduler =
        Executors.newSingleThreadScheduledExecutor(
            runnable -> {
              Thread thread = new Thread(runnable, "native-heap-pressure");
              thread.setDaemon(true);
              return thread;
            });
    monitor.scheduler.scheduleWithFixedDelay(monitor::sample, 1, 1, TimeUnit.SECONDS);
    return monitor;
  }

  // Sharing this lock with close() prevents cleanup from racing with invocation teardown.
  synchronized void sample() {
    if (closed || drops >= maxDrops) {
      return;
    }
    try {
      HeapUsage usage = heap.get();
      long now = nanoTime.getAsLong();
      if (usage.max() <= 0
          || usage.used() < 0
          || usage.used() > usage.max()
          || usage.used() < usage.max() * (threshold / 100.0)) {
        underPressure = false;
        return;
      }
      if (!underPressure) {
        underPressure = true;
        pressureStarted = now;
      }
      if (now - pressureStarted < sustainedNanos || (drops > 0 && now - lastDrop < cooldownNanos)) {
        return;
      }
      dropCaches.run();
      drops++;
      lastDrop = now;
      underPressure = false;
      logger.atInfo().log(
          "Dropped temporary caches after sustained sampled heap pressure: used=%d max=%d"
              + " threshold=%d drops=%d limit=%d. This is not a GC event.",
          usage.used(), usage.max(), threshold, drops, maxDrops);
    } catch (RuntimeException failure) {
      close();
      logger.atSevere().withCause(failure).log(
          "Sampled heap-pressure monitoring failed and stopped.");
      throw failure;
    }
  }

  synchronized int drops() {
    return drops;
  }

  @Override
  public synchronized void close() {
    closed = true;
    if (scheduler != null) {
      scheduler.shutdownNow();
    }
  }
}
