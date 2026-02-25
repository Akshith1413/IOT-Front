import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';
import '../main.dart';

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
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.cardBorder.withValues(alpha: 0.3),
              ),
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: AppColors.textPrimary, size: 20),
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
              ),
            ),
          ),
        ),
      ),
      body: ParticleBackground(
        particleCount: 55,
        baseColor: AppColors.plasmaViolet,
        accentColor: AppColors.auroraTeal,
        connectionDistance: 130,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(
                top: 100, left: 24, right: 24, bottom: 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  padding: const EdgeInsets.all(32.0),
                  decoration: AppDecorations.glassCard(
                    glowColor: AppColors.plasmaViolet,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Icon
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                AppColors.plasmaViolet.withValues(alpha: 0.25),
                                AppColors.auroraTeal.withValues(alpha: 0.08),
                              ],
                            ),
                          ),
                          child: const Icon(
                            Icons.person_add_rounded,
                            size: 56,
                            color: AppColors.plasmaViolet,
                          ),
                        ).animate().scale(
                            duration: 500.ms, curve: Curves.easeOutBack),

                        const SizedBox(height: 28),

                        const Text(
                          'Create Account',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.heading,
                        ).animate().fadeIn(delay: 200.ms).slideY(
                            begin: 0.3, end: 0),

                        const SizedBox(height: 8),
                        const Text(
                          'Join us to monitor your heart',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.subheading,
                        ).animate().fadeIn(delay: 300.ms).slideY(
                            begin: 0.3, end: 0),

                        const SizedBox(height: 48),

                        _buildTextField(
                          label: 'Full Name',
                          icon: Icons.person_outline,
                          onChanged: (val) => name = val,
                          validator: (val) =>
                              val!.isEmpty ? 'Enter your name' : null,
                        ).animate().fadeIn(delay: 350.ms).slideX(
                            begin: -0.2, end: 0),

                        const SizedBox(height: 16),

                        _buildTextField(
                          label: 'Email',
                          icon: Icons.email_outlined,
                          onChanged: (val) => email = val,
                          validator: (val) =>
                              val!.isEmpty ? 'Enter an email' : null,
                        ).animate().fadeIn(delay: 400.ms).slideX(
                            begin: -0.2, end: 0),

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
                            if (!val.contains(
                                RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) {
                              return 'Must contain at least one special character';
                            }
                            return null;
                          },
                        ).animate().fadeIn(delay: 500.ms).slideX(
                            begin: -0.2, end: 0),

                        const SizedBox(height: 24),

                        if (error.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16.0),
                            child: Text(
                              error,
                              style: const TextStyle(
                                color: AppColors.stellarRose,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ).animate().fadeIn(),

                        // Sign Up Button
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: const LinearGradient(
                              colors: [
                                AppColors.plasmaViolet,
                                Color(0xFF7C3AED),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.plasmaViolet
                                    .withValues(alpha: 0.4),
                                blurRadius: 20,
                                spreadRadius: -4,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ElevatedButton(
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
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: const Text(
                                                'Account created successfully!',
                                                style: TextStyle(
                                                  color: AppColors.deepSpace,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              backgroundColor:
                                                  AppColors.auroraTeal,
                                              behavior:
                                                  SnackBarBehavior.floating,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          );
                                          Navigator.of(context)
                                              .pushAndRemoveUntil(
                                            MaterialPageRoute(
                                                builder: (context) =>
                                                    const AuthWrapper()),
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
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
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
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    'Sign Up',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ).animate().fadeIn(delay: 600.ms).scale(),

                        const SizedBox(height: 24),

                        TextButton(
                          onPressed: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const LoginScreen()),
                            );
                          },
                          child: RichText(
                            text: const TextSpan(
                              text: "Already have an account? ",
                              style: AppTextStyles.subheading,
                              children: [
                                TextSpan(
                                  text: 'Sign In',
                                  style: TextStyle(
                                    color: AppColors.auroraTeal,
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
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: AppColors.textSecondary.withValues(alpha: 0.8),
          fontSize: 14,
        ),
        prefixIcon: Icon(icon,
            color: AppColors.plasmaViolet.withValues(alpha: 0.8), size: 22),
        filled: true,
        fillColor: AppColors.deepSpace.withValues(alpha: 0.6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: AppColors.cardBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              const BorderSide(color: AppColors.plasmaViolet, width: 1.5),
        ),
        errorStyle: const TextStyle(color: AppColors.stellarRose),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      obscureText: obscureText,
      onChanged: onChanged,
      validator: validator,
      cursorColor: AppColors.plasmaViolet,
    );
  }
}
