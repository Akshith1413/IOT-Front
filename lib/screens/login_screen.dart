import 'dart:ui';
import 'package:animate_gradient/animate_gradient.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/auth_service.dart';
import 'register_screen.dart';
import '../main.dart'; // Import main.dart to access AuthWrapper

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  String email = '';
  String password = '';
  String error = '';
  bool loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
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
          Color(0x2200D4FF), // Electric Blue hint
          Color(0xFF07090F),
          Color(0x1900FF9D), // Cyber Green hint
        ],
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
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
                        color: Color(0x0D00D4FF),
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
                            color: Color(0x2600D4FF),
                          ),
                          child: const Icon(
                            Icons.lock_outline_rounded,
                            size: 64,
                            color: Color(0xFF00D4FF),
                          ),
                        ).animate().scale(duration: 500.ms, curve: Curves.easeOutBack),
                        const SizedBox(height: 24),
                        const Text(
                          'Welcome Back',
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
                          'Sign in to your IoT Dashboard',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
                        ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.3, end: 0),
                        const SizedBox(height: 48),
                        _buildTextField(
                          label: 'Email Address',
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
                          validator: (val) =>
                              val!.length < 6 ? 'Password must be 6+ chars' : null,
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
                                          .signInWithEmailAndPassword(email, password);
                                      
                                      if (context.mounted) {
                                        Navigator.of(context).pushAndRemoveUntil(
                                          MaterialPageRoute(
                                              builder: (context) => const AuthWrapper()),
                                          (route) => false,
                                        );
                                      }
                                    } catch (e) {
                                      setState(() {
                                        error = 'Could not sign in with those credentials';
                                        loading = false;
                                      });
                                    }
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00D4FF),
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
                                  'Sign In',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                ),
                        ).animate().fadeIn(delay: 600.ms).scale(),
                        const SizedBox(height: 24),
                        TextButton(
                          onPressed: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (context) => const RegisterScreen()),
                            );
                          },
                          child: RichText(
                            text: const TextSpan(
                              text: "Don't have an account? ",
                              style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
                              children: [
                                TextSpan(
                                  text: 'Register',
                                  style: TextStyle(
                                    color: Color(0xFF00FF9D), // Cyber Green
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
        prefixIcon: Icon(icon, color: const Color(0xCC00D4FF), size: 22),
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
          borderSide: const BorderSide(color: Color(0xFF00D4FF), width: 1.5),
        ),
        errorStyle: const TextStyle(color: Color(0xFFFF2A6D)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      obscureText: obscureText,
      onChanged: onChanged,
      validator: validator,
      cursorColor: const Color(0xFF00D4FF),
    );
  }
}
