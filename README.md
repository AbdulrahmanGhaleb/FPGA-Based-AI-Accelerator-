# Overview

This repository contains my **Final Year Project (FYP)** for the **Bachelor of Electronics Engineering**.
The project demonstrates an **end-to-end embedded neural-network inference system**, combining:

* Embedded systems design
* FPGA hardware design using **VHDL**
* **RISC-V (NEORV32)** processor integration
* Bare-metal **C firmware development**
* Hardware–software interface design
* Fixed-point AI inference acceleration

The developed inference engine is **generic and reusable** for many embedded AI use cases.
For demonstration and validation, it is applied to a **weather comfort classification system**, where **temperature and humidity inputs** are processed to produce a comfort classification.

![System Block Diagram](SystemArchitecture.png)

---

# Neural Network Details

The neural network was designed and trained in **Python using TensorFlow**.
Its architecture is:

**2 → 16 → 16 → 8 → 1**

Training produces floating-point weights and biases, which are then **quantized** for embedded deployment.

Key points:

* Training and export are performed using the Python scripts included in this repository
* Weights are **quantized from float to int16**
* All parameters are exported to **C header files** for use by the firmware

Floating-point arithmetic is intentionally avoided in hardware due to its **high cost on embedded systems**.

---

# Inference Engine (AI Accelerator)

The inference engine is implemented as a **custom hardware accelerator** integrated inside a **NEORV32 RISC-V soft-core CPU**.

## Core Modules (High Level)

* **Matrix Multiplier (mm4x4)**

  * Purely combinational **4×4 matrix multiplier**
  * Unpacks bus data into matrices, performs multiplication, and packs results back
  * 4×4 size chosen to balance **DSP usage, timing, and FPGA resource limits**

* **Tiling & Buffering**

  * Larger matrices (up to 16×16) are processed using **4×4 tiling**
  * Intermediate results are accumulated using **tile buffers**
  * This approach scales to any dimension that is a multiple of 4

* **FSM Controller**

  * Coordinates all accelerator operations
  * Controls memory access, tiling sequence, accumulation, and completion
  * Clearly observable through simulation waveforms

* **Memory Interface**

  * Handles BRAM read/write operations
  * Streams data into tile buffers and retrieves computed results

* **NEORV32 CFS Interface**

  * Custom hardware–software interface
  * Memory-mapped registers for configuration, control, and status
  * Allows full control from C firmware

Understanding the accelerator operation is easiest by examining **testbench waveforms**, particularly from `tb2` and `tb3`.

---

# Testbenches

The repository includes multiple **VHDL testbenches** that verify:

* Register interface correctness
* FSM sequencing and state transitions
* BRAM read/write behavior
* Tiling and accumulation correctness
* Numerical correctness of matrix multiplication

These testbenches provide **cycle-accurate visibility** into the accelerator and were essential for validation.

---

# Quantization Strategy

The entire neural network operates in **fixed-point arithmetic**.

* **Weights:**

  * Quantized to **int16** directly in Python during export
* **Inputs (Temperature & Humidity):**

  * Quantized in firmware to **Q15**
* **Accumulation:**

  * Performed in **int32** for numerical safety
* **Layer Outputs:**

  * Requantized from int32 → int16 after each layer

### Q-Format Choice

* **Early layers:** higher precision (e.g. Q15)
* **Later layers:** wider dynamic range (e.g. Q13)

This trade-off preserves accuracy while preventing overflow.

---

# Padding

The accelerator processes matrices whose dimensions are **multiples of 4**.

Padding is applied in firmware:

* Vectors or matrices are extended with zeros
* Padding affects columns (and rows where required)
* Example:

  ```
  x = [x1, x2]
  x_padded = [x1, x2, 0, 0]
  ```

This ensures compatibility with the tiled hardware design.

---

# Firmware

The **bare-metal C firmware** running on the NEORV32 CPU is responsible for:

* Quantizing inputs and intermediate results
* Applying padding
* Loading matrices into accelerator memory
* Triggering accelerator execution
* Reading back results
* Applying bias addition and activation functions (ReLU, Sigmoid)
* Printing results via UART

Bias addition and activation functions are intentionally kept in software, as they are **computationally inexpensive** compared to matrix multiplication.

---

# UART Debugging & Compile-Time Logging

To validate correctness and numerical accuracy, the **neural-network inference was also executed entirely on the NEORV32 CPU** running on the FPGA.
These CPU results serve as **ground-truth benchmarks**, against which the **hardware accelerator outputs are compared**.

For this project, **zero numerical difference** was observed between:

* CPU-based inference results
* Accelerator-based inference results

The comparison focuses on **layer activations (post matrix multiplication)** and final outputs.



## Compile-Time Logging Modes

A **UART-based debugging and logging system** was implemented in the firmware.
This system is **configurable at compile time**, allowing different levels of verbosity without modifying runtime code.

### INFO Mode

* Minimal, human-readable output
* Prints:

  * Input values
  * Final layer outputs / predictions
  * High-level inference status
* Intended for:

  * Live demos
  * Clean result presentation
  * Avoiding UART flooding

### DEBUG Mode

* Detailed diagnostic output
* Prints:

  * Intermediate layer activations
  * Accelerator vs CPU comparison results
  * Maximum absolute differences (if any)
* Intended for:

  * Verification
  * Numerical validation
  * Debugging accelerator behavior

This separation ensures **clean demos** while still supporting **deep technical inspection** when needed.

---

## Stress-Test Mode

A dedicated **stress-test mode** was also implemented to further validate robustness.

In this mode:

* The neural network inference is executed for a **user-defined number of iterations**
* Each iteration uses **different input values**
* Outputs from the accelerator are continuously compared against CPU results
* Any mismatch or numerical error is recorded and reported via UART

This mode provides additional confidence in:

* Numerical stability
* Fixed-point correctness
* Hardware–software consistency across repeated executions

---

# Results

* Accelerator outputs **matched CPU reference results exactly**
* No numerical discrepancies were observed across:

  * Individual inference runs
  * Stress-test iterations
* This validates:

  * Correct tiling and accumulation
  * Correct fixed-point quantization strategy
  * Correct hardware–software integration

---


