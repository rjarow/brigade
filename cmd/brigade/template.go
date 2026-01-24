package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"brigade/internal/prd"
	"brigade/internal/util"
)

var templateCmd = &cobra.Command{
	Use:   "template [name] [resource]",
	Short: "Generate PRD from template",
	Long: `Generate a PRD from a template file with variable interpolation.

Without arguments, lists available templates.
With a template name, generates a PRD from that template.
Some templates require a resource name (e.g., "users" for an API template).`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return listTemplates()
		}

		templateName := args[0]
		resourceName := ""
		if len(args) > 1 {
			resourceName = args[1]
		}

		return runTemplate(templateName, resourceName)
	},
}

func listTemplates() error {
	fmt.Printf("%sAvailable Templates%s\n\n", colorBold, colorReset)

	found := false

	// List project templates
	projectDir := "brigade/templates"
	if entries, err := os.ReadDir(projectDir); err == nil && len(entries) > 0 {
		fmt.Printf("%sProject templates (brigade/templates/):%s\n", colorCyan, colorReset)
		for _, entry := range entries {
			if strings.HasSuffix(entry.Name(), ".json") {
				name := strings.TrimSuffix(entry.Name(), ".json")
				templatePath := filepath.Join(projectDir, entry.Name())
				desc := getTemplateDescription(templatePath)
				resourceNote := ""
				if templateRequiresResource(templatePath) {
					resourceNote = fmt.Sprintf(" %s(requires resource name)%s", colorDim, colorReset)
				}
				fmt.Printf("  %s%s%s - %s%s\n", colorGreen, name, colorReset, desc, resourceNote)
				found = true
			}
		}
		fmt.Println()
	}

	// List built-in templates
	builtinDir := findBuiltinTemplatesDir()
	if builtinDir != "" {
		if entries, err := os.ReadDir(builtinDir); err == nil && len(entries) > 0 {
			fmt.Printf("%sBuilt-in templates:%s\n", colorCyan, colorReset)
			for _, entry := range entries {
				if strings.HasSuffix(entry.Name(), ".json") {
					name := strings.TrimSuffix(entry.Name(), ".json")
					// Skip if overridden by project template
					if _, err := os.Stat(filepath.Join(projectDir, entry.Name())); err == nil {
						continue
					}
					templatePath := filepath.Join(builtinDir, entry.Name())
					desc := getTemplateDescription(templatePath)
					resourceNote := ""
					if templateRequiresResource(templatePath) {
						resourceNote = fmt.Sprintf(" %s(requires resource name)%s", colorDim, colorReset)
					}
					fmt.Printf("  %s%s%s - %s%s\n", colorGreen, name, colorReset, desc, resourceNote)
					found = true
				}
			}
			fmt.Println()
		}
	}

	if !found {
		fmt.Printf("%sNo templates found.%s\n\n", colorYellow, colorReset)
		fmt.Printf("Create templates in %sbrigade/templates/%s\n", colorCyan, colorReset)
	}

	fmt.Printf("%sUsage: ./brigade.sh template <name> [resource_name]%s\n", colorDim, colorReset)
	return nil
}

func runTemplate(templateName, resourceName string) error {
	// Find template file
	templateFile := findTemplate(templateName)
	if templateFile == "" {
		fmt.Printf("%sError: Template not found: %s%s\n\n", colorRed, templateName, colorReset)
		return listTemplates()
	}

	// Check if resource name is required
	if templateRequiresResource(templateFile) && resourceName == "" {
		fmt.Printf("%sError: Template '%s' requires a resource name%s\n\n", colorRed, templateName, colorReset)
		fmt.Printf("Usage: %s./brigade.sh template %s <resource_name>%s\n\n", colorCyan, templateName, colorReset)
		fmt.Println("Examples:")
		fmt.Printf("  ./brigade.sh template %s users\n", templateName)
		fmt.Printf("  ./brigade.sh template %s products\n", templateName)
		fmt.Printf("  ./brigade.sh template %s orders\n", templateName)
		return fmt.Errorf("resource name required")
	}

	// Determine output filename
	outputName := resourceName
	if outputName == "" {
		outputName = templateName
	}
	outputPath := fmt.Sprintf("brigade/tasks/prd-%s.json", outputName)

	// Check if output already exists
	if _, err := os.Stat(outputPath); err == nil {
		fmt.Printf("%sWarning: %s already exists%s\n", colorYellow, outputPath, colorReset)
		if !confirmPrompt("Overwrite? (y/N) ", false) {
			fmt.Printf("%sAborted.%s\n", colorDim, colorReset)
			return nil
		}
	}

	// Ensure output directory exists
	if err := os.MkdirAll(filepath.Dir(outputPath), 0755); err != nil {
		return err
	}

	// Read and interpolate template
	content, err := interpolateTemplate(templateFile, resourceName)
	if err != nil {
		return err
	}

	// Write output
	if err := os.WriteFile(outputPath, content, 0644); err != nil {
		return err
	}

	// Validate the generated PRD
	p, err := prd.Load(outputPath)
	if err != nil {
		fmt.Printf("%sError: Generated invalid JSON. Template may have syntax errors.%s\n", colorRed, colorReset)
		os.Remove(outputPath)
		return err
	}

	// Success message
	fmt.Println()
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
	fmt.Printf("%s║  PRD GENERATED FROM TEMPLATE                              ║%s\n", colorGreen, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorGreen, colorReset)

	fmt.Printf("%sFeature:%s  %s\n", colorBold, colorReset, p.FeatureName)
	fmt.Printf("%sTemplate:%s %s\n", colorBold, colorReset, templateName)
	fmt.Printf("%sTasks:%s    %d\n", colorBold, colorReset, len(p.Tasks))
	fmt.Printf("%sOutput:%s   %s\n\n", colorBold, colorReset, outputPath)

	fmt.Printf("%sNext steps:%s\n", colorDim, colorReset)
	fmt.Printf("  Review:   %scat %s | jq%s\n", colorCyan, outputPath, colorReset)
	fmt.Printf("  Validate: %s./brigade.sh validate %s%s\n", colorCyan, outputPath, colorReset)
	fmt.Printf("  Execute:  %s./brigade.sh service %s%s\n", colorCyan, outputPath, colorReset)
	fmt.Printf("  Dry-run:  %s./brigade.sh --dry-run service %s%s\n", colorCyan, outputPath, colorReset)

	return nil
}

func findBuiltinTemplatesDir() string {
	locations := []string{
		"brigade/templates",
		"templates",
	}
	for _, loc := range locations {
		if info, err := os.Stat(loc); err == nil && info.IsDir() {
			return loc
		}
	}
	return ""
}

func findTemplate(name string) string {
	// Check project templates first
	projectPath := filepath.Join("brigade/templates", name+".json")
	if _, err := os.Stat(projectPath); err == nil {
		return projectPath
	}

	// Check built-in templates
	builtinDir := findBuiltinTemplatesDir()
	if builtinDir != "" {
		builtinPath := filepath.Join(builtinDir, name+".json")
		if _, err := os.Stat(builtinPath); err == nil {
			return builtinPath
		}
	}

	return ""
}

func templateRequiresResource(templatePath string) bool {
	content, err := os.ReadFile(templatePath)
	if err != nil {
		return false
	}
	return strings.Contains(string(content), "{{name}}")
}

func getTemplateDescription(templatePath string) string {
	content, err := os.ReadFile(templatePath)
	if err != nil {
		return "No description"
	}

	var data map[string]interface{}
	if err := json.Unmarshal(content, &data); err != nil {
		return "No description"
	}

	if desc, ok := data["description"].(string); ok {
		return strings.ReplaceAll(desc, "{{name}}", "X")
	}
	if name, ok := data["featureName"].(string); ok {
		return strings.ReplaceAll(name, "{{name}}", "X")
	}
	return "No description"
}

func interpolateTemplate(templatePath, resource string) ([]byte, error) {
	content, err := os.ReadFile(templatePath)
	if err != nil {
		return nil, err
	}

	if resource == "" {
		return content, nil
	}

	result := string(content)

	// Replace all placeholder variants
	result = strings.ReplaceAll(result, "{{name}}", resource)
	result = strings.ReplaceAll(result, "{{Name}}", util.ToCapitalized(resource))
	result = strings.ReplaceAll(result, "{{NAME}}", strings.ToUpper(resource))

	singular := util.ToSingular(resource)
	result = strings.ReplaceAll(result, "{{name_singular}}", singular)
	result = strings.ReplaceAll(result, "{{Name_singular}}", util.ToCapitalized(singular))

	return []byte(result), nil
}
