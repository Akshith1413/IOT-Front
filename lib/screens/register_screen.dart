import 'dart:ui';
import 'package:animate_gradient/animate_gradient.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';
import '../main.dart'; // Import main.dart to access AuthWrapper

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  String email = '';
  String password = '';
  String name = '';
  String error = '';
  bool loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0x19FFFFFF),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
              ),
            ),
          ),
        ),
      ),
      body: AnimateGradient(
        primaryBegin: Alignment.topLeft,
        primaryEnd: Alignment.bottomLeft,
        secondaryBegin: Alignment.bottomLeft,
        secondaryEnd: Alignment.topRight,
        primaryColors: const [
          Color(0xFF141933), // Deep Indigo
          Color(0xFF07090F), // True Black edge
          Color(0xFF141933),
        ],
        secondaryColors: [
          const Color(0x2600FF9D), // Cyber Green hint
          const Color(0xFF07090F),
          const Color(0x1900D4FF), // Electric Blue hint
        ],
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 100, left: 24, right: 24, bottom: 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  padding: const EdgeInsets.all(32.0),
                  decoration: BoxDecoration(
                    color: const Color(0x07FFFFFF),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0x1AFFFFFF), width: 1.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0D00FF9D),
                        blurRadius: 40,
                        spreadRadius: -10,
                      )
                    ],
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0x2600FF9D),
                          ),
                          child: const Icon(
                            Icons.person_add_rounded,
                            size: 64,
                            color: Color(0xFF00FF9D),
                          ),
                        ).animate().scale(duration: 500.ms, curve: Curves.easeOutBack),
                        const SizedBox(height: 24),
                        const Text(
                          'Create Account',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.3, end: 0),
                        const SizedBox(height: 8),
                        const Text(
                          'Join us to monitor your heart',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
                        ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.3, end: 0),
                        const SizedBox(height: 48),
                        _buildTextField(
                          label: 'Full Name',
                          icon: Icons.person_outline,
                          onChanged: (val) => name = val,
                          validator: (val) => val!.isEmpty ? 'Enter your name' : null,
                        ).animate().fadeIn(delay: 350.ms).slideX(begin: -0.2, end: 0),
                        const SizedBox(height: 16),
                        _buildTextField(
                          label: 'Email',
                          icon: Icons.email_outlined,
                          onChanged: (val) => email = val,
                          validator: (val) => val!.isEmpty ? 'Enter an email' : null,
                        ).animate().fadeIn(delay: 400.ms).slideX(begin: -0.2, end: 0),
                        const SizedBox(height: 16),
                        _buildTextField(
                          label: 'Password',
                          icon: Icons.lock_outline,
                          obscureText: true,
                          onChanged: (val) => password = val,
                          validator: (val) {
                            if (val == null || val.isEmpty) {
                              return 'Enter a password';
                            }
                            if (val.length < 7) {
                              return 'Password must be 7+ chars';
                            }
                            if (!val.contains(RegExp(r'[A-Z]'))) {
                              return 'Must contain at least one uppercase letter';
                            }
                            if (!val.contains(RegExp(r'[0-9]'))) {
                              return 'Must contain at least one number';
                            }
                            if (!val.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) {
                              return 'Must contain at least one special character';
                            }
                            return null;
                          },
                        ).animate().fadeIn(delay: 500.ms).slideX(begin: -0.2, end: 0),
                        const SizedBox(height: 24),
                        if (error.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16.0),
                            child: Text(
                              error,
                              style: const TextStyle(color: Color(0xFFFF2A6D), fontSize: 13, fontWeight: FontWeight.w600),
                              textAlign: TextAlign.center,
                            ),
                          ).animate().fadeIn(),
                        ElevatedButton(
                          onPressed: loading
                              ? null
                              : () async {
                                  if (_formKey.currentState!.validate()) {
                                    setState(() => loading = true);
                                    try {
                                      await context
                                          .read<AuthService>()
                                          .registerWithEmailAndPassword(
                                              email, password, name);
                                              
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: const Text('Account created successfully!', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                                            backgroundColor: const Color(0xFF00FF9D),
                                            behavior: SnackBarBehavior.floating,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          ),
                                        );
                                        Navigator.of(context).pushAndRemoveUntil(
                                          MaterialPageRoute(
                                              builder: (context) => const AuthWrapper()),
                                          (route) => false,
                                        );
                                      }
                                    } catch (e) {
                                      setState(() {
                                        error = e.toString();
                                        loading = false;
                                      });
                                    }
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF9D),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.black87,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  'Sign Up',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                ),
                        ).animate().fadeIn(delay: 600.ms).scale(),
                        const SizedBox(height: 24),
                        TextButton(
                          onPressed: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (context) => const LoginScreen()),
                            );
                          },
                          child: RichText(
                            text: const TextSpan(
                              text: "Already have an account? ",
                              style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
                              children: [
                                TextSpan(
                                  text: 'Sign In',
                                  style: TextStyle(
                                    color: Color(0xFF00D4FF), // Electric Blue
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ).animate().fadeIn(delay: 700.ms),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required IconData icon,
    required Function(String) onChanged,
    String? Function(String?)? validator,
    bool obscureText = false,
  }) {
    return TextFormField(
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
        prefixIcon: Icon(icon, color: const Color(0xCC00FF9D), size: 22),
        filled: true,
        fillColor: const Color(0x4D000000),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x0DFFFFFF), width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF00FF9D), width: 1.5),
        ),
        errorStyle: const TextStyle(color: Color(0xFFFF2A6D)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      obscureText: obscureText,
      onChanged: onChanged,
      validator: validator,
      cursorColor: const Color(0xFF00FF9D),
    );
  }
}
