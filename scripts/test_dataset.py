import numpy as np
import pandas as pd

# ==============================
# Configuration
# ==============================
NUM_SAMPLES = 500
RANDOM_SEED = 42

# Input ranges (realistic sensor values)
T_MIN, T_MAX = 18.0, 35.0
H_MIN, H_MAX = 20.0, 90.0

# Comfort boundary parameters (ground truth)
T0 = 26.0
H0 = 50.0
a  = 5.0
b  = 15.0

# Fixed-point configuration
Q_FRAC_BITS = 8        # Q8.8 format
Q_SCALE = 1 << Q_FRAC_BITS

# Output files
CSV_FILE = "comfort_test_set_hw.csv"
C_HEADER_FILE = "comfort_test_set.h"

# ==============================
# Generate dataset
# ==============================
np.random.seed(RANDOM_SEED)

T = np.random.uniform(T_MIN, T_MAX, NUM_SAMPLES)
H = np.random.uniform(H_MIN, H_MAX, NUM_SAMPLES)

# Boundary equation (ground truth)
value = ((T - T0) / a) ** 2 + ((H - H0) / b) ** 2
labels = (value <= 1.0).astype(int)

# ==============================
# Quantization (Q8.8)
# ==============================
def quantize(x):
    return np.round(x * Q_SCALE).astype(np.int16)

T_q = quantize(T)
H_q = quantize(H)

# ==============================
# Save CSV 
# ==============================
df = pd.DataFrame({
    "T_q": T_q,
    "H_q": H_q,
    "Label": labels
})

df.to_csv("test_dataset.csv", index=False)
print(f"[OK] CSV test set saved: {CSV_FILE}")

# ==============================
# Generate C header for firmware
# ==============================
with open(C_HEADER_FILE, "w") as f:
    f.write("#ifndef COMFORT_TEST_SET_H\n")
    f.write("#define COMFORT_TEST_SET_H\n\n")

    f.write("#include <stdint.h>\n\n")

    f.write(f"#define TEST_SET_SIZE {NUM_SAMPLES}\n")
    f.write(f"#define INPUT_Q_FRAC_BITS {Q_FRAC_BITS}\n\n")

    # Temperature array
    f.write("static const int16_t test_T_q[TEST_SET_SIZE] = {\n")
    for i, v in enumerate(T_q):
        f.write(f"  {v},")
        if (i + 1) % 8 == 0:
            f.write("\n")
    f.write("\n};\n\n")

    # Humidity array
    f.write("static const int16_t test_H_q[TEST_SET_SIZE] = {\n")
    for i, v in enumerate(H_q):
        f.write(f"  {v},")
        if (i + 1) % 8 == 0:
            f.write("\n")
    f.write("\n};\n\n")

    # Labels
    f.write("static const uint8_t test_label[TEST_SET_SIZE] = {\n")
    for i, v in enumerate(labels):
        f.write(f"  {v},")
        if (i + 1) % 16 == 0:
            f.write("\n")
    f.write("\n};\n\n")

    f.write("#endif // COMFORT_TEST_SET_H\n")

print(f"[OK] C header test set saved: {C_HEADER_FILE}")
