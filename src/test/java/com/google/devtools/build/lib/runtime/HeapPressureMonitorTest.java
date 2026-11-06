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

import static com.google.common.truth.Truth.assertThat;
import static org.junit.Assert.assertThrows;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.JUnit4;

@RunWith(JUnit4.class)
public final class HeapPressureMonitorTest {
  private final AtomicLong clock = new AtomicLong();
  private final AtomicReference<HeapPressureMonitor.HeapUsage> heap =
      new AtomicReference<>(new HeapPressureMonitor.HeapUsage(90, 100));
  private final AtomicInteger drops = new AtomicInteger();

  private HeapPressureMonitor monitor(Runnable callback) {
    return new HeapPressureMonitor(
        heap::get, clock::get, callback, 85, 3, Duration.ofSeconds(3), Duration.ofSeconds(30));
  }

  private void sample(HeapPressureMonitor monitor, int seconds) {
    clock.set(Duration.ofSeconds(seconds).toNanos());
    monitor.sample();
  }

  @Test
  public void transientPressureDoesNotDropCaches() {
    try (var monitor = monitor(drops::incrementAndGet)) {
      sample(monitor, 0);
      sample(monitor, 2);
      heap.set(new HeapPressureMonitor.HeapUsage(50, 100));
      sample(monitor, 3);
      heap.set(new HeapPressureMonitor.HeapUsage(90, 100));
      sample(monitor, 4);
      sample(monitor, 6);
      assertThat(drops.get()).isEqualTo(0);
      sample(monitor, 7);
      assertThat(drops.get()).isEqualTo(1);
    }
  }

  @Test
  public void sustainedPressureRespectsCooldownAndInvocationLimit() {
    try (var monitor = monitor(drops::incrementAndGet)) {
      for (int second = 0; second <= 100; second++) {
        sample(monitor, second);
        int expected = second < 3 ? 0 : second < 33 ? 1 : second < 63 ? 2 : 3;
        assertThat(drops.get()).isEqualTo(expected);
      }
      assertThat(monitor.drops()).isEqualTo(3);
    }
  }

  @Test
  public void invalidReadingsResetSustainedPressure() {
    try (var monitor = monitor(drops::incrementAndGet)) {
      for (var invalid :
          new HeapPressureMonitor.HeapUsage[] {
            new HeapPressureMonitor.HeapUsage(1, -1),
            new HeapPressureMonitor.HeapUsage(1, 0),
            new HeapPressureMonitor.HeapUsage(-1, 100),
            new HeapPressureMonitor.HeapUsage(101, 100)
          }) {
        heap.set(new HeapPressureMonitor.HeapUsage(90, 100));
        monitor.sample();
        clock.addAndGet(Duration.ofSeconds(2).toNanos());
        heap.set(invalid);
        monitor.sample();
        clock.addAndGet(Duration.ofSeconds(10).toNanos());
        heap.set(new HeapPressureMonitor.HeapUsage(90, 100));
        monitor.sample();
      }
      assertThat(drops.get()).isEqualTo(0);
    }
  }

  @Test
  public void closedInvocationCannotDropCachesOrCarryPressureIntoNextInvocation() {
    var previous = monitor(drops::incrementAndGet);
    sample(previous, 0);
    previous.close();
    sample(previous, 100);
    assertThat(drops.get()).isEqualTo(0);
    try (var next = monitor(drops::incrementAndGet)) {
      sample(next, 100);
      sample(next, 102);
      assertThat(drops.get()).isEqualTo(0);
      sample(next, 103);
      assertThat(drops.get()).isEqualTo(1);
    }
  }

  @Test
  public void callbackFailureStopsMonitoringWithoutRecordingSuccessfulDrop() {
    try (var monitor =
        monitor(
            () -> {
              throw new IllegalStateException("failed cleanup");
            })) {
      sample(monitor, 0);
      assertThrows(IllegalStateException.class, () -> sample(monitor, 3));
      sample(monitor, 40);
      assertThat(monitor.drops()).isEqualTo(0);
    }
  }

  @Test
  public void closeWaitsForInFlightCleanup() throws Exception {
    CountDownLatch entered = new CountDownLatch(1);
    CountDownLatch release = new CountDownLatch(1);
    CountDownLatch closeStarted = new CountDownLatch(1);
    try (var executor = Executors.newFixedThreadPool(2);
        var monitor =
            monitor(
                () -> {
                  entered.countDown();
                  try {
                    if (!release.await(5, TimeUnit.SECONDS))
                      throw new AssertionError("cleanup not released");
                  } catch (InterruptedException e) {
                    throw new AssertionError(e);
                  }
                  drops.incrementAndGet();
                })) {
      sample(monitor, 0);
      clock.set(Duration.ofSeconds(3).toNanos());
      var sampling = executor.submit(monitor::sample);
      assertThat(entered.await(5, TimeUnit.SECONDS)).isTrue();
      var closing =
          executor.submit(
              () -> {
                closeStarted.countDown();
                monitor.close();
              });
      try {
        assertThat(closeStarted.await(5, TimeUnit.SECONDS)).isTrue();
        assertThat(closing.isDone()).isFalse();
      } finally {
        release.countDown();
      }
      sampling.get(5, TimeUnit.SECONDS);
      closing.get(5, TimeUnit.SECONDS);
      sample(monitor, 100);
      assertThat(drops.get()).isEqualTo(1);
    }
  }
}
