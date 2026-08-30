import os
import glob
import numpy as np
from PIL import Image
import tensorflow as tf
from tensorflow.keras import layers, models, optimizers
from sklearn.model_selection import train_test_split

def load_dataset(dataset_root):
    class_names = ['no_nut', 'nut_present']
    image_paths = []
    labels = []

    for label_idx, class_name in enumerate(class_names):
        class_dir = os.path.join(dataset_root, class_name)
        pattern = os.path.join(class_dir, '**', '*.jpg')
        found_files = glob.glob(pattern, recursive=True)
        print(f"Found {len(found_files)} images for class '{class_name}' ({label_idx})")
        for p in found_files:
            image_paths.append(p)
            labels.append(label_idx)

    return image_paths, labels, class_names

def preprocess_image(path, target_size=(160, 160)):
    img = Image.open(path).convert('RGB')
    img = img.resize(target_size, Image.Resampling.BILINEAR)
    arr = np.array(img, dtype=np.float32) / 255.0
    return arr

def create_dataset(image_paths, labels, target_size=(160, 160)):
    X = []
    y = []
    for p, l in zip(image_paths, labels):
        X.append(preprocess_image(p, target_size))
        y.append(l)

    X = np.array(X, dtype=np.float32)
    y = np.array(y, dtype=np.float32)

    return X, y

def build_ultralight_model(input_shape=(160, 160, 3)):
    """
    Ultra-lightweight Depthwise Separable ConvNet (~4k params, ~20 KB TFLite).
    Ideal for real-time edge hardware (Raspberry Pi, Android, Microcontrollers).
    """
    inputs = layers.Input(shape=input_shape)

    x = layers.RandomFlip("horizontal_and_vertical")(inputs)
    x = layers.RandomRotation(0.15)(x)

    # Conv Block 1
    x = layers.Conv2D(16, (3, 3), strides=(2, 2), padding='same', use_bias=False)(x)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU(6.0)(x)

    # Depthwise Separable Block 1
    x = layers.DepthwiseConv2D((3, 3), strides=(1, 1), padding='same', use_bias=False)(x)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU(6.0)(x)
    x = layers.Conv2D(32, (1, 1), padding='same', use_bias=False)(x)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU(6.0)(x)
    x = layers.MaxPool2D((2, 2))(x)

    # Depthwise Separable Block 2
    x = layers.DepthwiseConv2D((3, 3), strides=(1, 1), padding='same', use_bias=False)(x)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU(6.0)(x)
    x = layers.Conv2D(64, (1, 1), padding='same', use_bias=False)(x)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU(6.0)(x)
    x = layers.MaxPool2D((2, 2))(x)

    x = layers.GlobalAveragePooling2D()(x)
    x = layers.Dropout(0.2)(x)
    outputs = layers.Dense(1, activation='sigmoid')(x)

    model = models.Model(inputs=inputs, outputs=outputs, name="UltraLight_Nut_Detector")
    return model

def build_mobilenetv3_small(input_shape=(160, 160, 3)):
    """
    MobileNetV3 Small transfer learning model (~1 MB TFLite).
    Higher capacity for extreme lighting or angle variations.
    """
    base_model = tf.keras.applications.MobileNetV3Small(
        input_shape=input_shape,
        include_top=False,
        weights='imagenet',
        pooling='avg'
    )
    base_model.trainable = True
    for layer in base_model.layers[:-15]:
        layer.trainable = False

    inputs = layers.Input(shape=input_shape)
    x = layers.RandomFlip("horizontal_and_vertical")(inputs)
    x = base_model(x)
    x = layers.Dropout(0.2)(x)
    outputs = layers.Dense(1, activation='sigmoid')(x)

    model = models.Model(inputs=inputs, outputs=outputs, name="MobileNetV3Small_Nut_Detector")
    return model

def save_tflite(model, output_path):
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_content = converter.convert()

    with open(output_path, "wb") as f:
        f.write(tflite_content)

    size_kb = len(tflite_content) / 1024.0
    print(f"-> Exported TFLite Model: {output_path} ({size_kb:.2f} KB)")
    return size_kb

def main():
    dataset_root = "/Users/abhay/Desktop/arecanut_final/binary_dataset/BinaryDetector"
    output_dir = "/Users/abhay/Desktop/arecanut_final/tflite_output"
    os.makedirs(output_dir, exist_ok=True)

    print("=== Loading Binary Dataset ===")
    image_paths, labels, class_names = load_dataset(dataset_root)

    if len(image_paths) == 0:
        raise ValueError(f"No images found in {dataset_root}!")

    X, y = create_dataset(image_paths, labels, target_size=(160, 160))

    X_train, X_val, y_train, y_val = train_test_split(
        X, y, test_size=0.25, random_state=42, stratify=y
    )

    print(f"\nTrain set: {len(X_train)} samples | Validation set: {len(X_val)} samples")

    # 1. Train UltraLight Model (~20 KB)
    print("\n==========================================")
    print("  Training UltraLight ConvNet (~4,000 params)")
    print("==========================================")
    ultralight_model = build_ultralight_model(input_shape=(160, 160, 3))
    ultralight_model.compile(
        optimizer=optimizers.Adam(learning_rate=1e-3),
        loss='binary_crossentropy',
        metrics=['accuracy']
    )

    callbacks = [
        tf.keras.callbacks.EarlyStopping(monitor='val_accuracy', patience=15, restore_best_weights=True),
        tf.keras.callbacks.ReduceLROnPlateau(monitor='val_loss', factor=0.5, patience=5, min_lr=1e-5)
    ]

    ultralight_model.fit(
        X_train, y_train,
        validation_data=(X_val, y_val),
        epochs=50,
        batch_size=8,
        callbacks=callbacks,
        verbose=1
    )

    val_loss, val_acc = ultralight_model.evaluate(X_val, y_val)
    print(f"\n[UltraLight ConvNet] Val Loss: {val_loss:.4f} | Val Accuracy: {val_acc * 100:.2f}%")

    ultralight_tflite_path = os.path.join(output_dir, "arecanut_binary_ultralight.tflite")
    save_tflite(ultralight_model, ultralight_tflite_path)

    # 2. Train MobileNetV3 Small Model (~1 MB)
    print("\n==========================================")
    print("  Training MobileNetV3 Small Model")
    print("==========================================")
    mobilenet_model = build_mobilenetv3_small(input_shape=(160, 160, 3))
    mobilenet_model.compile(
        optimizer=optimizers.Adam(learning_rate=3e-4),
        loss='binary_crossentropy',
        metrics=['accuracy']
    )

    mobilenet_model.fit(
        X_train, y_train,
        validation_data=(X_val, y_val),
        epochs=35,
        batch_size=8,
        callbacks=callbacks,
        verbose=1
    )

    mn_val_loss, mn_val_acc = mobilenet_model.evaluate(X_val, y_val)
    print(f"\n[MobileNetV3 Small] Val Loss: {mn_val_loss:.4f} | Val Accuracy: {mn_val_acc * 100:.2f}%")

    mobilenet_tflite_path = os.path.join(output_dir, "arecanut_binary_mobilenetv3.tflite")
    save_tflite(mobilenet_model, mobilenet_tflite_path)

    # Save Labels
    labels_path = os.path.join(output_dir, "labels.txt")
    with open(labels_path, "w") as f:
        f.write("no_nut\nnut_present\n")

    print("\n==========================================")
    print("  SUCCESSFULLY GENERATED TFLITE MODELS!")
    print("==========================================")
    print(f"1. UltraLight Model (< 25 KB): {ultralight_tflite_path}")
    print(f"2. MobileNetV3 Model (~1 MB): {mobilenet_tflite_path}")
    print(f"3. Labels: {labels_path}")

if __name__ == "__main__":
    main()
