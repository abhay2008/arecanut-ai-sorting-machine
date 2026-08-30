import os
import sys
import glob
import zipfile
import shutil
import re
import numpy as np
import tensorflow as tf
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix

print("==========================================================================")
print("     ARECA NUT MULTI-INPUT MODEL TRAINING & TFLITE EXPORT PIPELINE        ")
print("==========================================================================")
print(f"TensorFlow Version: {tf.__version__}")
print(f"Python Version: {sys.version}")

# Set random seeds for reproducibility
SEED = 123
tf.random.set_seed(SEED)
np.random.seed(SEED)

# -----------------------------------------------------------------------------
# 1. DIRECTORY INSPECTION & EXTRACTION
# -----------------------------------------------------------------------------
user_downloads = os.path.expanduser("~/Downloads")
zip_candidates = sorted(glob.glob(os.path.join(user_downloads, "*arecanut*.zip")), key=os.path.getmtime, reverse=True)

if not zip_candidates:
    # Fallback to any zip in downloads if specific name not found
    zip_candidates = sorted(glob.glob(os.path.join(user_downloads, "*.zip")), key=os.path.getmtime, reverse=True)

if not zip_candidates:
    raise FileNotFoundError("No dataset zip file found in ~/Downloads/")

target_zip = zip_candidates[0]
print(f"\n[STEP 1] Found dataset archive: {target_zip}")

extract_dir = "./areca_dataset"
if os.path.exists(extract_dir):
    shutil.rmtree(extract_dir)

os.makedirs(extract_dir, exist_ok=True)
print(f"Extracting contents to '{extract_dir}'...")

with zipfile.ZipFile(target_zip, 'r') as zip_ref:
    zip_ref.extractall(extract_dir)

print("Extraction complete.")

# -----------------------------------------------------------------------------
# 2. DATASET PARSING, CLASS FILTERING & METADATA EXTRACTION
# -----------------------------------------------------------------------------
# Target classes mapping: standardizing directory names to canonical class names
TARGET_CLASSES = {
    'bette': 'Bette',
    'goragalu': 'Goragalu',
    'hasa': 'Hasa',
    'rashi_edi': 'Rashi edi',
    'rashi edi': 'Rashi edi',
    'rashiedi': 'Rashi edi'
}

# Sorted canonical class list for index encoding: 0->Bette, 1->Goragalu, 2->Hasa, 3->Rashi edi
CANONICAL_CLASSES = ['Bette', 'Goragalu', 'Hasa', 'Rashi edi']
CLASS_TO_IDX = {cls_name: i for i, cls_name in enumerate(CANONICAL_CLASSES)}

print(f"\nTarget Classes: {CANONICAL_CLASSES}")

image_paths = []
metadata_list = []
labels_list = []
sample_weights_list = []

valid_extensions = ('.jpg', '.jpeg', '.png', '.bmp', '.webp')

for root, dirs, files in os.walk(extract_dir):
    # Check for excluded binary classification directories or non-target folders
    root_lower = root.lower()
    if any(ex in root_lower for ex in ['good', 'bad', 'healthy', 'diseased', 'binary']):
        continue

    for f in files:
        if not f.lower().endswith(valid_extensions):
            continue
        if f.startswith('.') or f.endswith('.csv'):
            continue
        
        full_path = os.path.join(root, f)
        rel_path = os.path.relpath(full_path, extract_dir)
        path_parts = rel_path.lower().split(os.sep)

        # Determine class label from path parts
        detected_class = None
        for part in path_parts:
            # Clean string for matching
            clean_part = part.replace('-', '_').replace(' ', '_')
            if clean_part in TARGET_CLASSES:
                detected_class = TARGET_CLASSES[clean_part]
                break
            elif part in TARGET_CLASSES:
                detected_class = TARGET_CLASSES[part]
                break

        if detected_class is None:
            # Exclude files outside target 4 classes
            continue

        label_idx = CLASS_TO_IDX[detected_class]

        # Extract Zoom
        # 1x -> 1.0, 3x -> 3.0
        if '3x' in rel_path.lower():
            zoom = 3.0
        else:
            zoom = 1.0

        # Extract Exposure
        # ev_-0.5, ev_0.0, ev_+0.5 or -0.5, 0.0, 0.5
        ev_match = re.search(r'ev_([+-]?\d+\.?\d*)', rel_path, re.IGNORECASE)
        if ev_match:
            try:
                exposure = float(ev_match.group(1))
            except ValueError:
                exposure = 0.0
        else:
            exposure = 0.0

        # Extract Torch / Flash
        if 'flash' in rel_path.lower() or 'torch' in rel_path.lower():
            torch_flag = 1.0
        else:
            torch_flag = 0.0

        # Sample weight: 1.5 for 3x zoom, 1.0 for 1x zoom
        sample_weight = 1.5 if zoom == 3.0 else 1.0

        image_paths.append(full_path)
        metadata_list.append([zoom, exposure, torch_flag])
        labels_list.append(label_idx)
        sample_weights_list.append(sample_weight)

print(f"Total valid images parsed across 4 target classes: {len(image_paths)}")
for cls_name, idx in CLASS_TO_IDX.items():
    count = labels_list.count(idx)
    print(f"  Class '{cls_name}' (ID {idx}): {count} samples")

if len(image_paths) == 0:
    raise ValueError("No matching image samples found for the 4 target classes!")

# -----------------------------------------------------------------------------
# 3. DATA SPLITTING & TF.DATA PIPELINE CONSTRUCT
# -----------------------------------------------------------------------------
print("\n[STEP 2] Splitting dataset into 80% Train / 20% Validation (Seed: 123)...")

(
    train_paths, val_paths,
    train_meta, val_meta,
    train_labels, val_labels,
    train_weights, val_weights
) = train_test_split(
    image_paths, metadata_list, labels_list, sample_weights_list,
    test_size=0.20, random_state=SEED, stratify=labels_list
)

print(f"Training samples: {len(train_paths)}")
print(f"Validation samples: {len(val_paths)}")

IMG_SIZE = (224, 224)
BATCH_SIZE = 16

def load_and_preprocess_image(path):
    img_raw = tf.io.read_file(path)
    img = tf.image.decode_jpeg(img_raw, channels=3)
    img = tf.image.resize(img, IMG_SIZE)
    return img

def create_dataset(paths, meta, labels, weights, is_training=True):
    path_ds = tf.data.Dataset.from_tensor_slices(paths)
    img_ds = path_ds.map(load_and_preprocess_image, num_parallel_calls=tf.data.AUTOTUNE)
    
    meta_ds = tf.data.Dataset.from_tensor_slices(tf.constant(meta, dtype=tf.float32))
    label_ds = tf.data.Dataset.from_tensor_slices(tf.constant(labels, dtype=tf.int32))
    weight_ds = tf.data.Dataset.from_tensor_slices(tf.constant(weights, dtype=tf.float32))

    # Inputs dataset as tuple of (image_tensor, metadata_tensor)
    input_ds = tf.data.Dataset.zip((img_ds, meta_ds))

    # Complete tuple dataset yielding ((image, metadata), label, sample_weight)
    dataset = tf.data.Dataset.zip((input_ds, label_ds, weight_ds))

    if is_training:
        dataset = dataset.shuffle(buffer_size=len(paths), seed=SEED)

    dataset = dataset.batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)
    return dataset

train_ds = create_dataset(train_paths, train_meta, train_labels, train_weights, is_training=True)
val_ds = create_dataset(val_paths, val_meta, val_labels, val_weights, is_training=False)

# -----------------------------------------------------------------------------
# 4. MODEL ARCHITECTURE BUILDING
# -----------------------------------------------------------------------------
print("\n[STEP 3] Building Functional Multi-Input Dual-Stream Keras Model...")

# Image Stream Input
image_input = tf.keras.layers.Input(shape=(224, 224, 3), name='image_input')
rescaled_images = tf.keras.applications.mobilenet_v3.preprocess_input(image_input)

base_model = tf.keras.applications.MobileNetV3Small(
    input_shape=(224, 224, 3),
    include_top=False,
    weights='imagenet'
)

img_features_map = base_model(rescaled_images)
img_features = tf.keras.layers.GlobalAveragePooling2D(name='global_avg_pooling')(img_features_map)

# Metadata Stream Input [zoom, exposure, torch]
meta_input = tf.keras.layers.Input(shape=(3,), name='metadata_input')

# Texture Attention/Scaling conditioned on zoom input (first element of metadata input)
zoom_feat = tf.keras.layers.Lambda(lambda x: x[:, 0:1], name='extract_zoom')(meta_input)
zoom_dense = tf.keras.layers.Dense(16, activation='relu', name='zoom_attn_dense')(zoom_feat)
channel_dim = img_features.shape[-1]
zoom_attn_weights = tf.keras.layers.Dense(channel_dim, activation='sigmoid', name='channel_attention_weights')(zoom_dense)

# Apply dynamic channel-wise weighting to image features
weighted_img_features = tf.keras.layers.Multiply(name='texture_attention_scaling')([img_features, zoom_attn_weights])

# Metadata dense stream
x_meta = tf.keras.layers.Dense(16, activation='relu', name='meta_dense1')(meta_input)
x_meta = tf.keras.layers.Dense(8, activation='relu', name='meta_dense2')(x_meta)

# Combined Classification Head
combined = tf.keras.layers.Concatenate(name='concat_features')([weighted_img_features, x_meta])
x = tf.keras.layers.Dense(64, activation='relu', name='head_dense1')(combined)
x = tf.keras.layers.Dropout(0.3, name='head_dropout')(x)
output = tf.keras.layers.Dense(len(CANONICAL_CLASSES), activation='softmax', name='classification_output')(x)

model = tf.keras.Model(inputs=[image_input, meta_input], outputs=output, name='areca_nut_dual_input_model')
model.summary()

# -----------------------------------------------------------------------------
# 5. PHASE 1 TRAINING (BACKBONE FROZEN)
# -----------------------------------------------------------------------------
print("\n[STEP 4] Phase 1 Training (MobileNetV3 Backbone Frozen)...")
base_model.trainable = False

model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
    loss='sparse_categorical_crossentropy',
    metrics=['accuracy']
)

history_phase1 = model.fit(
    train_ds,
    validation_data=val_ds,
    epochs=15
)

# -----------------------------------------------------------------------------
# 6. PHASE 2 FINE-TUNING (UNFREEZE TOP 30 LAYERS)
# -----------------------------------------------------------------------------
print("\n[STEP 5] Phase 2 Fine-Tuning (Unfreezing Top 30 Layers of Backbone)...")

base_model.trainable = True
# Freeze all layers except the top 30 layers
num_layers = len(base_model.layers)
fine_tune_at = num_layers - 30

for layer in base_model.layers[:fine_tune_at]:
    layer.trainable = False

for layer in base_model.layers[fine_tune_at:]:
    # Keep Batch Normalization layers in inference mode for stability if needed
    if isinstance(layer, tf.keras.layers.BatchNormalization):
        layer.trainable = False
    else:
        layer.trainable = True

# Cosine Decay Learning Rate Schedule starting at 1e-5
total_fine_tune_steps = 15 * len(train_ds)
lr_schedule = tf.keras.optimizers.schedules.CosineDecay(
    initial_learning_rate=1e-5,
    decay_steps=total_fine_tune_steps,
    alpha=0.01
)

model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=lr_schedule),
    loss='sparse_categorical_crossentropy',
    metrics=['accuracy']
)

history_phase2 = model.fit(
    train_ds,
    validation_data=val_ds,
    epochs=15
)

# -----------------------------------------------------------------------------
# 7. MODEL EVALUATION & METRICS REPORT
# -----------------------------------------------------------------------------
print("\n[STEP 6] Evaluating Model Performance on Validation Set...")

val_preds = []
val_true = []

for (img_b, meta_b), label_b, _ in val_ds:
    preds_b = model.predict([img_b, meta_b], verbose=0)
    pred_classes_b = np.argmax(preds_b, axis=1)
    val_preds.extend(pred_classes_b)
    val_true.extend(label_b.numpy())

print("\n--------------------------------------------------------------------------")
print("                     CLASSIFICATION REPORT (VALIDATION)                    ")
print("--------------------------------------------------------------------------")
clf_report = classification_report(val_true, val_preds, target_names=CANONICAL_CLASSES, digits=4)
print(clf_report)

print("--------------------------------------------------------------------------")
print("                         CONFUSION MATRIX                                 ")
print("--------------------------------------------------------------------------")
cm = confusion_matrix(val_true, val_preds)
print("Labels:", CANONICAL_CLASSES)
print(cm)

# -----------------------------------------------------------------------------
# 8. TFLITE CONVERSION (FP16 QUANTIZATION) & EXPORT
# -----------------------------------------------------------------------------
print("\n[STEP 7] Converting Trained Dual-Input Model to TFLite (FP16 Quantization)...")

converter = tf.lite.TFLiteConverter.from_keras_model(model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.target_spec.supported_types = [tf.float16]

tflite_quant_model = converter.convert()

tflite_model_filename = "areca_nut_dual_input.tflite"
labels_filename = "labels.txt"

with open(tflite_model_filename, "wb") as f:
    f.write(tflite_quant_model)

print(f"\nSaved FP16 Quantized TFLite Model to: '{tflite_model_filename}'")
print(f"Model File Size: {os.path.getsize(tflite_model_filename) / (1024 * 1024):.2f} MB")

# Save labels.txt line-separated in exact model output index order
with open(labels_filename, "w") as f:
    for cls_name in CANONICAL_CLASSES:
        f.write(f"{cls_name}\n")

print(f"Saved class labels to: '{labels_filename}'")

# -----------------------------------------------------------------------------
# 9. TFLITE SIGNATURE VERIFICATION
# -----------------------------------------------------------------------------
print("\n[STEP 8] Inspecting TFLite Input/Output Signature & Tensor Details:")

interpreter = tf.lite.Interpreter(model_path=tflite_model_filename)
interpreter.allocate_tensors()

input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

print("\n--- TFLite Input Tensors ---")
for i, detail in enumerate(input_details):
    print(f"Input [{i}] Name: '{detail['name']}', Shape: {detail['shape']}, DataType: {detail['dtype']}")

print("\n--- TFLite Output Tensors ---")
for i, detail in enumerate(output_details):
    print(f"Output [{i}] Name: '{detail['name']}', Shape: {detail['shape']}, DataType: {detail['dtype']}")

print("\n==========================================================================")
print("     PIPELINE EXECUTED SUCCESSFULLY! ALL OUTPUT ARTIFACTS GENERATED.       ")
print("==========================================================================")
