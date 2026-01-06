import pandas as pd
import numpy as np
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense

# Load data
X_train = pd.read_csv("train_features.csv").values
y_train = pd.read_csv("train_labels.csv").values.reshape(-1)

X_test = pd.read_csv("test_features.csv").values
y_test = pd.read_csv("test_labels.csv").values.reshape(-1)

# Normalize 
X_train = X_train / np.array([35.0, 100.0])
X_test  = X_test  / np.array([35.0, 100.0])


# Build model
model = Sequential([
    Dense(16, activation='relu', input_shape=(2,)),
    Dense(16, activation='relu'),
    Dense(8, activation='relu'),
    Dense(1, activation='sigmoid')
])


model.compile(optimizer='adam',
              loss='binary_crossentropy',
              metrics=['accuracy'])

# Train
model.fit(X_train, y_train, epochs=200, batch_size=16)

# Evaluate
loss, accuracy = model.evaluate(X_test, y_test)
print("Test accuracy:", accuracy)

model.save("comfort_model.h5")

weights = model.get_weights()

for w in weights:
    print(w.shape)
    print(w)
def to_c_array(name, arr):
    flat = arr.flatten()
    txt = f"float {name}[{len(flat)}] = {{ "
    txt += ", ".join(f"{x:.6f}" for x in flat)
    txt += " };"
    return txt

W1, b1, W2, b2, W3, b3, W4, b4 = weights

def quantize_to_int16(W):
    max_val = np.max(np.abs(W))
    scale = max_val / 32767.0 if max_val != 0 else 1.0
    W_int16 = np.round(W / scale).astype(np.int16)
    return W_int16, scale
# Quantize all weights
W1_q, s1 = quantize_to_int16(W1)
W2_q, s2 = quantize_to_int16(W2)
W3_q, s3 = quantize_to_int16(W3)
W4_q, s4 = quantize_to_int16(W4)

# Save quantized weights + scales for CPU
np.savez("quantized_weights.npz",
         W1=W1_q, s1=s1,
         W2=W2_q, s2=s2,
         W3=W3_q, s3=s3,
         W4=W4_q, s4=s4,
         b1=b1, b2=b2, b3=b3, b4=b4)

print("Quantization complete.")
print("Scales:", s1, s2, s3, s4)

def to_c_int16_array(name, arr):
    flat = arr.flatten()
    txt = f"int16_t {name}[{len(flat)}] = {{ "
    txt += ", ".join(str(int(x)) for x in flat)
    txt += " };"
    return txt

def to_c_float(name, val):
    return f"float {name} = {val:.10f};"

with open("nn_weights_quantized.h", "w") as f:
    f.write("// Quantized weights for FPGA accelerator\n\n")

    # Layer 1
    f.write(to_c_int16_array("W1_q", W1_q) + ";\n")
    f.write(to_c_array("b1", b1) + ";\n")
    f.write(to_c_float("s1", s1) + ";\n\n")

    # Layer 2
    f.write(to_c_int16_array("W2_q", W2_q) + ";\n")
    f.write(to_c_array("b2", b2) + ";\n")
    f.write(to_c_float("s2", s2) + ";\n\n")

    # Layer 3
    f.write(to_c_int16_array("W3_q", W3_q) + ";\n")
    f.write(to_c_array("b3", b3) + ";\n")
    f.write(to_c_float("s3", s3) + ";\n\n")

    # Layer 4
    f.write(to_c_int16_array("W4_q", W4_q) + ";\n")
    f.write(to_c_array("b4", b4) + ";\n")
    f.write(to_c_float("s4", s4) + ";\n\n")

print("Header file nn_weights_quantized.h generated.")

