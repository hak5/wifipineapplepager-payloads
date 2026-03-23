# Password Generator
 
**Description:** Generate secure random passwords and save them locally.

---

## 📌 Overview
This script is a **Password Generator** designed for environments that support **DuckyScript Bash payloads** (such as devices running payload frameworks). It allows a user to:

- Generate a random password
- Choose a password name and length
- Automatically include:
  - Uppercase letters
  - Lowercase letters
  - Numbers
  - Special characters
- Save the generated password to a file
- View previously generated passwords

All generated passwords are stored in a dedicated folder for easy retrieval.

---

## 📂 Folder Structure

```
/mmc/root/payloads/user/general/Password_Generator/
│
├── Password_Generator.sh
└── ALL_PASSWORDS/
    ├── example_password.txt
    └── another_password.txt
```

Passwords are saved inside the **ALL_PASSWORDS** directory.

---

## ⚙️ Features

✅ Random password generation  
✅ User‑defined password name  
✅ Adjustable password length  
✅ Automatic inclusion of multiple character sets  
✅ Secure Fisher‑Yates shuffle  
✅ Saved password history  
✅ Option to view all stored passwords  

---

## 🔐 Password Generation Method

The script guarantees password complexity by:

1. Selecting **one character from each character set**:
   - Uppercase
   - Lowercase
   - Numbers
   - Special characters

2. Filling the remaining characters randomly.

3. Shuffling the final password using the **Fisher‑Yates algorithm** to ensure randomness.

---

## 🧰 Character Sets Used

```
Uppercase: A-Z
Lowercase: a-z
Numbers:   0-9
Special:   !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
```

---

## ▶️ How It Works

1. The script starts with a prompt explaining the tool.
2. It checks for previously saved passwords.
3. If passwords exist, the user can choose to **view them**.
4. The user is prompted to:
   - Enter a **password name**
   - Select a **password length**
5. A password is generated and shuffled.
6. The password is **saved to a `.txt` file** in:

```
/mmc/root/payloads/user/general/Password_Generator/ALL_PASSWORDS/
```

7. The generated password is displayed to the user.

---

## 💾 Example Saved File

```
My_PC
G7!kPz3@QaL$
```

The first line is the **password name**, and the second line is the **generated password**.

---

## 🛡 Security Notes

- Uses Bash's built-in `RANDOM` function for randomness.
- Fisher‑Yates shuffle improves distribution of characters.
- Ensures at least **one character from each category**.
- Password names are sanitized to avoid invalid filenames.

---

## 📜 License

This project is provided as-is for educational and personal use.
